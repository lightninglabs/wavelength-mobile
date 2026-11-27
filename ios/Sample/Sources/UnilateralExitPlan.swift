import Foundation
import WalletKit

struct UnilateralExitOptions: Equatable, Sendable {
    var sweepAddress = ""
    var feeRateSatPerVByte: Int64 = 0

    func matchesQuotedAddress(_ address: String) -> Bool {
        let isBech32 = ["bc1", "tb1", "bcrt1", "sb1"].contains { sweepAddress.lowercased().hasPrefix($0) }
        return isBech32 ? address.lowercased() == sweepAddress.lowercased() : address == sweepAddress
    }
}

struct UnilateralExitQuote {
    let preview: UnilateralExitPreview
    let options: UnilateralExitOptions

    init(preview: UnilateralExitPreview, outpoints: [String], options: UnilateralExitOptions) throws {
        guard !outpoints.isEmpty, preview.entries.map(\.outpoint) == outpoints,
              preview.feeRateSatPerVByte > 0 else {
            throw WalletActionError(message: "Couldn’t verify the selected funds.")
        }
        guard options.matchesQuotedAddress(preview.sweepAddress),
              options.feeRateSatPerVByte == 0 || preview.feeRateSatPerVByte == options.feeRateSatPerVByte else {
            throw WalletActionError(message: "The wallet did not confirm the custom exit options.")
        }
        self.preview = preview
        self.options = options
    }

    var rate: Int64 { preview.feeRateSatPerVByte }
    var needsFunding: Bool { preview.additionalFundingSat > 0 }
    var blocked: [UnilateralExitTarget] {
        preview.entries.filter { !$0.admissionError.isEmpty || $0.exitStatus != "unspecified" }
    }
    var economicBlock: Bool {
        blocked.contains { ["uneconomical", "sweep_below_dust"].contains($0.infeasibilityReason) }
    }
    var allUneconomical: Bool {
        preview.entries.allSatisfy { $0.infeasibilityReason == "uneconomical" }
    }

    func blockedMessage(_ entry: UnilateralExitTarget) -> String {
        if entry.exitStatus != "unspecified" { return "Exit already started" }
        switch entry.infeasibilityReason {
        case "sweep_below_dust": return "Too small at this fee rate"
        case "uneconomical": return "Fees would use up this amount"
        default: return "Can’t exit with these settings"
        }
    }
}

struct UnilateralExitSelectionPlan {
    let entries: [ExitPlanEntry]
    let feeRate: Int64?
    let canStart: Bool

    init(plan: ExitPlan, outpoints: [String], options: UnilateralExitOptions) throws {
        guard !outpoints.isEmpty, let entries = plan.plans,
              entries.map(\.outpoint) == outpoints else {
            throw WalletActionError(message: "Couldn’t verify the selected funds.")
        }
        let address = plan.sweepAddress ?? ""
        guard options.matchesQuotedAddress(address),
              options.feeRateSatPerVByte == 0 ||
                (plan.feeRateSatPerVByte == options.feeRateSatPerVByte && plan.totalEstimatedFeeSat != nil) else {
            throw WalletActionError(message: "The wallet did not confirm the custom exit options.")
        }
        self.entries = entries
        feeRate = plan.feeRateSatPerVByte
        canStart = plan.canStart && entries.allSatisfy { $0.canStart && !$0.exitJobFound && $0.error.isEmpty }
    }

    var fundingEntry: ExitPlanEntry? {
        let blocked = entries.filter { !$0.canStart || $0.exitJobFound || !$0.error.isEmpty }
        guard blocked.allSatisfy({ UnilateralExitFunding($0) != nil }) else { return nil }
        return blocked.first
    }

    var funding: UnilateralExitFunding? { fundingEntry.flatMap(UnilateralExitFunding.init) }
}

enum UnilateralExitAdmission {
    case starting, started, unconfirmed(String)

    var title: String {
        switch self {
        case .starting: return "Starting"
        case .started: return "Started"
        case .unconfirmed: return "Check exit status"
        }
    }

    var error: String? {
        if case .unconfirmed(let message) = self { return message }
        return nil
    }
}

struct UnilateralExitFunding {
    let address: String
    let paymentCount: Int64
    let satsPerPayment: Int64

    init?(_ entry: ExitPlanEntry) {
        let missingInputs = Int64(entry.requiredFeeUTXOCount) - Int64(entry.usableFeeUTXOCount)
        // Older SDKs can supply a shortfall even when funding cannot help.
        let needsFunding: Bool
        switch entry.infeasibilityReason {
        case "wallet_underfunded": needsFunding = entry.fundingShortfallSat > 0
        case "wallet_too_few_inputs": needsFunding = missingInputs > 0
        default: needsFunding = false
        }
        guard !entry.canStart, !entry.exitJobFound, entry.error.isEmpty,
              entry.roundCommitment.isEmpty, !entry.fundingAddress.isEmpty, needsFunding else { return nil }
        address = entry.fundingAddress
        paymentCount = max(1, missingInputs)
        let shortfall = max(0, entry.fundingShortfallSat)
        let minimum = shortfall / paymentCount + (shortfall % paymentCount == 0 ? 0 : 1)
        satsPerPayment = max(entry.recommendedUTXOAmountSat, minimum)
        guard satsPerPayment > 0 else { return nil }
    }

    var instructions: String {
        let amount = WalletFormatting.sats(satsPerPayment)
        return paymentCount == 1 ? "Send \(amount) to this address."
            : "Send \(paymentCount) separate payments of \(amount) each."
    }
}

enum UnilateralExitStage: Equatable {
    case checking, publishing, waiting, sweeping, complete, failed

    init(status: String?) {
        switch status {
        case "materializing": self = .publishing
        case "csv_pending": self = .waiting
        case "sweeping": self = .sweeping
        case "completed": self = .complete
        case "failed": self = .failed
        default: self = .checking
        }
    }

    var title: String {
        switch self {
        case .checking: return "Checking exit status"
        case .publishing: return "Publishing exit transactions"
        case .waiting: return "Waiting for block delay"
        case .sweeping: return "Sweep confirming"
        case .complete: return "Exit complete"
        case .failed: return "Action needed"
        }
    }

    var queueTitle: String {
        switch self {
        case .publishing: return "Publishing on-chain"
        case .waiting: return "Waiting for block delay"
        case .sweeping: return "Awaiting Bitcoin confirmation"
        case .complete: return "Complete"
        case .checking, .failed: return title
        }
    }

    var isTerminal: Bool { self == .complete || self == .failed }
}
