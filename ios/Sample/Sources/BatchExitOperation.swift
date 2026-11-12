import Foundation
import WalletKit

enum BatchExitState: String, Codable {
    case checking, queued, complete, failed

    var title: String {
        switch self {
        case .checking: return "Checking status"
        case .queued: return "Exiting"
        case .complete: return "Exited"
        case .failed: return "Not exited"
        }
    }
    var isPending: Bool { self == .checking || self == .queued }
}

struct BatchExitInput: Codable, Identifiable, Equatable {
    let outpoint: String
    let amountSat: Int64
    var state: BatchExitState = .checking
    var message: String = ""
    var entryID: String?
    var id: String { outpoint }
}

/// Written before the one native dispatch. Unknown inputs remain reserved in
/// the host across navigation and restart; this receipt is never replayed.
struct BatchExitOperation: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let existingEntryIDs: Set<String>
    var destination: String
    var inputs: [BatchExitInput]
    var error: String?
    var activityID: String?

    init(funds: [WalletVTXO], destination: String, activity: [Entry], now: Date = Date()) {
        id = UUID()
        startedAt = now
        existingEntryIDs = Set(activity.map(\.id))
        self.destination = destination
        inputs = funds.map { BatchExitInput(outpoint: $0.outpoint, amountSat: $0.amountSat) }
    }

    var amountSat: Int64 { inputs.reduce(0) { $0 + $1.amountSat } }
    var isPending: Bool { inputs.contains { $0.state.isPending } }

    mutating func apply(_ result: ExitBatchResult) {
        if !result.destination.isEmpty { destination = result.destination }
        activityID = result.activityID.flatMap { $0.isEmpty ? nil : $0 }
        let results = Dictionary(grouping: result.results ?? [], by: \.outpoint)
        for index in inputs.indices {
            // Missing or duplicate responses are not proof of non-admission.
            guard let matches = results[inputs[index].outpoint], matches.count == 1 else { continue }
            let match = matches[0]
            switch match.outcome {
            case "accepted":
                inputs[index].state = .queued
                inputs[index].entryID = activityID
            case "failed": inputs[index].state = .failed
            default: inputs[index].state = .checking
            }
            inputs[index].message = match.error
        }
    }

    mutating func reconcile(_ activity: [Entry]) {
        // If the response was lost, a fresh native batch row covering the
        // whole principal can recover the handle. The host reserves every
        // selected input before dispatch, so no second app batch can own it.
        // A smaller aggregate cannot identify an unknown accepted subset.
        if activityID == nil, inputs.allSatisfy({ $0.state == .checking }) {
            let matches = activity.filter { entry in
                entry.kind == "exit" && entry.id.hasPrefix("batch-exit-") &&
                    !existingEntryIDs.contains(entry.id) &&
                    entry.progress?.vtxoOutpoint == inputs.first?.outpoint &&
                    entry.amountSat == -amountSat &&
                    (destination.isEmpty || entry.request?.onchainAddress == destination) &&
                    WalletFormatting.parsedDate(entry.createdAt).map {
                        $0 >= Date(timeIntervalSince1970: startedAt.timeIntervalSince1970.rounded(.down))
                    } == true
            }
            if matches.count == 1, let entry = matches.first {
                activityID = entry.id
                if destination.isEmpty { destination = entry.request?.onchainAddress ?? "" }
                for index in inputs.indices { inputs[index].entryID = entry.id }
            }
        }
        // The native batch creates one activity row for the accepted subset,
        // so its round fee is counted once. Unknown inputs never inherit it.
        if let activityID, let entry = activity.first(where: { $0.id == activityID && $0.kind == "exit" }) {
            for index in inputs.indices where inputs[index].state.isPending && inputs[index].entryID == activityID {
                update(index, from: entry)
            }
        }
        for index in inputs.indices where inputs[index].state.isPending {
            let input = inputs[index]
            if let activityID, input.entryID == activityID { continue }
            let matches = activity.filter { entry in
                guard entry.kind == "exit", entry.counterparty != "unilateral",
                      entry.progress?.vtxoOutpoint == input.outpoint else { return false }
                if let entryID = input.entryID { return entry.id == entryID }
                guard !existingEntryIDs.contains(entry.id),
                      abs(entry.amountSat) == input.amountSat,
                      let created = WalletFormatting.parsedDate(entry.createdAt),
                      created >= Date(timeIntervalSince1970: startedAt.timeIntervalSince1970.rounded(.down)) else { return false }
                // A lost own-wallet response may not reveal its generated address.
                return destination.isEmpty || entry.request?.onchainAddress == destination
            }
            guard matches.count == 1, let entry = matches.first else { continue }
            inputs[index].entryID = entry.id
            update(index, from: entry)
        }
    }

    private mutating func update(_ index: Int, from entry: Entry) {
        switch entry.status {
        case "complete": inputs[index].state = .complete
        case "failed": inputs[index].state = .failed
        default: inputs[index].state = .queued
        }
        inputs[index].message = entry.failureReason ?? ""
    }
}

struct BatchExitFee {
    let totalSat: Int64
    let canExit: Bool

    init(funds: [WalletVTXO], estimates: [ExitFeeEstimate]) throws {
        let quotes = Dictionary(grouping: estimates, by: \.outpoint)
        var total: Int64 = 0
        var viable = !funds.isEmpty
        for fund in funds {
            guard let matches = quotes[fund.outpoint], matches.count == 1,
                  let quote = matches.first, quote.amountSat == fund.amountSat,
                  quote.estimatedFeeSat >= 0 else {
                throw WalletActionError(message: "The fee estimate does not match the selected funds.")
            }
            let sum = total.addingReportingOverflow(quote.estimatedFeeSat)
            guard !sum.overflow else { throw WalletActionError(message: "The fee estimate is too large.") }
            total = sum.partialValue
            viable = viable && quote.canExit
        }
        totalSat = total
        canExit = viable
    }
}

/// A corrupt or unreadable journal blocks new admission. Atomic replacement
/// plus synchronization must succeed before any funds-moving call is made.
enum BatchExitJournal {
    static func load(_ url: URL) throws -> [BatchExitOperation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([BatchExitOperation].self, from: Data(contentsOf: url))
    }

    static func save(_ operations: [BatchExitOperation], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(operations).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }
}
