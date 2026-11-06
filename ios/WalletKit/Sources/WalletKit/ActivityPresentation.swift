import Foundation

/// Plain wallet labels derived only from durable activity and observed phases.
public extension Entry {
    var isExpiredInvoice: Bool {
        kind == "receive" && status == "failed" && failureCode == "expired"
    }

    var activityStatus: String { isExpiredInvoice ? "expired" : status }

    var isCredit: Bool { kind == "receive" || kind == "deposit" }

    var isLightningActivity: Bool { activityRailLabel == "Lightning" }

    var activityRailLabel: String {
        switch request?.type.lowercased() {
        case "lightning": return "Lightning"
        case "onchain": return "On-chain"
        case "ark": return "Ark"
        default:
            if kind == "receive" { return "Lightning" }
            if kind == "deposit" || kind == "exit" { return "On-chain" }
            if !(progress?.paymentHash ?? "").isEmpty { return "Lightning" }
            return "Not reported"
        }
    }

    var activityDirectionLabel: String {
        if isAwaitingIncomingPayment || isExpiredInvoice { return "Incoming request" }
        return isCredit ? "Incoming" : "Outgoing"
    }

    var isAwaitingIncomingPayment: Bool {
        guard isCredit, status == "pending" else { return false }
        let phase = progress?.phase ?? ""
        let label = progress?.phaseLabel ?? ""
        let requestOnlyPhases = [
            "request_created", "waiting_for_payment", "address_issued", "unspecified",
        ]
        let lifecycle = label.isEmpty ? phase : label
        return lifecycle.isEmpty || requestOnlyPhases.contains(lifecycle)
    }

    var displayStatus: String {
        if failureCode == "needs_intervention" { return "Action needed" }
        if progress?.phase == "refunding" { return "Refunding" }
        if failureCode == "refunded" || progress?.phase == "refunded" { return "Refunded" }
        if isExpiredInvoice { return "Expired" }
        if status == "failed" { return "Failed" }
        if status == "pending" {
            if isAwaitingIncomingPayment { return "Waiting for payment" }
            if isCredit { return "Receiving" }
            return kind == "send" ? "Sending" : "In progress"
        }
        if status == "complete" {
            if isCredit { return "Received" }
            return kind == "send" ? "Sent" : "Complete"
        }
        return "Checking status"
    }

    var isCreditTopup: Bool { kind == "send" && progress?.phaseLabel == "credit_topup" }

    var activityPaymentHash: String? {
        if let hash = progress?.paymentHash, !hash.isEmpty { return hash }
        if let hash = request?.paymentHash, !hash.isEmpty { return hash }
        return nil
    }

    var activityTitle: String {
        if isCreditTopup { return "Credit top-up" }
        if !note.isEmpty { return note }
        switch kind {
        case "send": return "Payment"
        case "receive", "deposit": return "Bitcoin"
        case "exit": return "Exit"
        case "refresh": return "Refresh"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Groups only explicitly correlated funding legs; raw Activity stays intact.
public enum WalletActivityPresentation {
    public static func entries(_ entries: [Entry]) -> [Entry] {
        let paymentHashes = Set(entries.filter { $0.kind == "send" && !$0.isCreditTopup }
            .compactMap(\.activityPaymentHash))
        return entries.filter { entry in
            guard entry.isCreditTopup, entry.status != "failed",
                  let hash = entry.activityPaymentHash else { return true }
            return !paymentHashes.contains(hash)
        }
    }

    public static func creditTopups(for payment: Entry, in entries: [Entry]) -> [Entry] {
        guard payment.kind == "send", !payment.isCreditTopup,
              let hash = payment.activityPaymentHash else { return [] }
        return entries.filter { $0.isCreditTopup && $0.activityPaymentHash == hash }
    }
}
