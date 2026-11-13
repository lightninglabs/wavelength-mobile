import Foundation
import WalletKit

struct DiagnosticRun: Codable, Identifiable {
    struct Event: Codable, Identifiable {
        var id: String { "\(time):\(label)" }
        let time: Int64
        let label: String
        var elapsedMilliseconds: Double? = nil
        var durationMilliseconds: Double? = nil
    }
    let id: String
    let network: String
    let started: Int64
    let trigger: String
    var wake: DiagnosticWakeContext? = nil
    var startup: String? = nil
    var hostBudgetSeconds: Int? = nil
    var nativeBudgetSeconds: Int? = nil
    var elapsedAtFinish: Double? = nil
    var deferred: Bool? = nil
    var interrupted: Bool? = nil
    var budgetExhausted: Bool? = nil
    var receiptProofs: Int? = nil
    var completedReceipts: Int? = nil
    var finished: Int64?
    var status = "Running"
    var events: [Event] = []
    var batches: UInt32?
    var checked: UInt32?
    var more: Bool?
    var needsForeground: Bool?
    var duration: Double { (elapsedAtFinish ?? Double((finished ?? DiagnosticJournal.now) - started)) / 1000 }
}

/// Stores observations from actual host callbacks. This is neither a wake
/// scheduler nor proof that the daemon completed a round or refreshed funds.
@MainActor
final class DiagnosticJournal: ObservableObject {
    static let shared = DiagnosticJournal()
    nonisolated static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    @Published private(set) var runs: [DiagnosticRun] = []
    @Published private(set) var entries: [DiagnosticLogRecord] = []
    private let file: URL
    private let uptime: () -> TimeInterval
    private var beganAt: [String: TimeInterval] = [:]

    private let read: (URL) throws -> Data
    private var historyUnavailable = false

    init(file: URL? = nil, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WavelengthDiagnostics/journal.json")
        self.uptime = uptime
        self.read = read
        restoreHistory()
    }

    private func restoreHistory() {
        do {
            let stored = try JSONDecoder().decode(Saved.self, from: read(file))
            let currentIDs = Set(runs.map(\.id))
            let currentEntryIDs = Set(entries.map(\.id))
            let restored = stored.runs.filter { !currentIDs.contains($0.id) }.map { saved in
                var run = saved
                // A previous process cannot complete an old observation.
                if run.finished == nil {
                    run.status = "End not recorded"
                    run.finished = run.events.last?.time ?? run.started
                }
                return run
            }
            runs = Array((restored + runs).sorted { $0.started < $1.started }.suffix(50))
            entries = Array((stored.entries.filter { !currentEntryIDs.contains($0.id) } + entries)
                .sorted { $0.time < $1.time }.suffix(200))
            historyUnavailable = false
        } catch CocoaError.fileReadNoSuchFile {
            historyUnavailable = false
        } catch {
            // A push before first unlock can create this singleton while the
            // history file is protected. Retry before any later write; never
            // replace unreadable history with an empty process-local journal.
            historyUnavailable = true
        }
    }

    func begin(id: String, network: String, trigger: String, wake: DiagnosticWakeContext? = nil) {
        guard !runs.contains(where: { $0.id == id }) else { return }
        beganAt[id] = uptime()
        runs.append(DiagnosticRun(id: id, network: network, started: Self.now,
                                  trigger: trigger, wake: wake, hostBudgetSeconds: 20,
                                  events: [.init(time: Self.now, label: "Wake received", elapsedMilliseconds: 0)]))
        runs = Array(runs.suffix(50))
        beganAt = beganAt.filter { key, _ in runs.contains { $0.id == key } }
        record(id: id, network: network, label: "Background opportunity: \(trigger)")
    }

    func event(id: String, network: String, label: String, durationMilliseconds: Double? = nil) {
        if let index = runs.firstIndex(where: { $0.id == id }) {
            runs[index].events.append(.init(time: Self.now, label: label, elapsedMilliseconds: elapsed(id), durationMilliseconds: durationMilliseconds))
            runs[index].events = Array(runs[index].events.suffix(64))
        }
        record(id: id, network: network, label: label)
    }

    private func elapsed(_ id: String) -> Double? {
        beganAt[id].map { max(0, (uptime() - $0) * 1000) }
    }

    func context(id: String, startup: String? = nil, nativeBudget: Int? = nil) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        if let startup { runs[index].startup = startup }
        if let nativeBudget { runs[index].nativeBudgetSeconds = nativeBudget }
        save()
    }

    /// Observe an existing call without changing its task or error semantics.
    func measure<T>(id: String?, network: String, label: String,
                    operation: () async throws -> T) async rethrows -> T {
        let start = uptime()
        do {
            let value = try await operation()
            if let id { event(id: id, network: network, label: label, durationMilliseconds: max(0, (uptime() - start) * 1000)) }
            return value
        } catch {
            if let id { event(id: id, network: network, label: label + " failed", durationMilliseconds: max(0, (uptime() - start) * 1000)) }
            throw error
        }
    }

    func measureSync<T>(id: String?, network: String, label: String, operation: () throws -> T) rethrows -> T {
        let start = uptime()
        do {
            let value = try operation()
            if let id { event(id: id, network: network, label: label, durationMilliseconds: max(0, (uptime() - start) * 1000)) }
            return value
        } catch {
            if let id { event(id: id, network: network, label: label + " failed", durationMilliseconds: max(0, (uptime() - start) * 1000)) }
            throw error
        }
    }

    func finish(id: String, network: String, result: ReceiptWindowResult? = nil, status: String? = nil) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        // OS completion can precede native cleanup. Keep the first terminal
        // outcome while retaining counters from a native call that returns later.
        if let result {
            runs[index].batches = result.batches
            runs[index].checked = result.maintenanceChecked
            runs[index].more = result.maintenanceMore
            runs[index].needsForeground = result.needsForeground
            runs[index].deferred = result.maintenanceDeferred
            runs[index].interrupted = result.interrupted
            runs[index].budgetExhausted = result.budgetExhausted
            runs[index].receiptProofs = result.receipts.count
            runs[index].completedReceipts = result.receipts.filter { $0.state == "complete" }.count
        }
        guard runs[index].finished == nil else { save(); return }
        let state = status ?? (result?.budgetExhausted == true ? "Budget exhausted" :
            result?.interrupted == true ? "Interrupted" : "Yielded")
        runs[index].finished = Self.now
        runs[index].elapsedAtFinish = elapsed(id)
        runs[index].status = state
        runs[index].events.append(.init(time: Self.now, label: state, elapsedMilliseconds: elapsed(id)))
        runs[index].events = Array(runs[index].events.suffix(64))
        record(id: id, network: network, label: state)
    }

    func record(id: String = "", network: String, label: String) {
        entries.append(.init(id: UUID().uuidString, time: Self.now, level: "INFO",
            source: "App/\(network)", message: id.isEmpty ? label : "\(label) [\(id)]"))
        entries = Array(entries.suffix(200))
        save()
    }

    private struct Saved: Codable {
        let runs: [DiagnosticRun]
        let entries: [DiagnosticLogRecord]
    }

    private func save() {
        if historyUnavailable { restoreHistory() }
        guard !historyUnavailable else { return }
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        if let data = try? JSONEncoder().encode(Saved(runs: runs, entries: entries)) {
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
