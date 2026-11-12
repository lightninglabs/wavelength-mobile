import Foundation
import WalletKit

struct PendingDispatch: Codable, Identifiable {
    let intentID: String
    let amountSat: Int64
    let paymentHash: String
    var selectedOutpoints: [String]? = nil
    var existingEntryIDs: [String]? = nil
    var startedAt: Date? = nil
    var error: String? = nil
    var checks: Int? = nil
    var destination: String? = nil

    var id: String { intentID }
    var canStartSeparatePayment: Bool { (checks ?? 0) >= 2 }

    /// A historical attempt is not evidence that this dispatch was accepted.
    /// Missing timing/baseline metadata stays uncertain, including old receipts.
    func matches(_ entry: Entry) -> Bool {
        guard entry.kind == "send" || entry.kind == "exit",
              entry.progress?.phaseLabel != "credit_topup",
              amountSat <= 0 || abs(entry.amountSat) == amountSat,
              let existingEntryIDs, !existingEntryIDs.contains(entry.id),
              let startedAt, let created = WalletFormatting.parsedDate(entry.createdAt),
              created >= Date(timeIntervalSince1970: startedAt.timeIntervalSince1970.rounded(.down)) else { return false }
        return entry.id == intentID || (!paymentHash.isEmpty &&
            (entry.progress?.paymentHash == paymentHash || entry.request?.paymentHash == paymentHash)) ||
            (entry.kind == "exit" && destination != nil && entry.request?.onchainAddress == destination &&
             entry.progress.map { selectedOutpoints?.contains($0.vtxoOutpoint) == true } == true)
    }
}

struct SweepOperation: Codable, Identifiable {
    let destination: String
    var amountSat: Int64
    let feeRate: Int64
    var txid: String = ""
    var status: String = "Checking transfer"
    var error: String? = nil
    var startedAt: Date? = nil
    var checks: Int? = nil

    var id: String { txid.isEmpty ? destination + String(startedAt?.timeIntervalSince1970 ?? 0) : txid }
    var canStartSeparateTransfer: Bool { txid.isEmpty && (checks ?? 0) >= 2 }
}
