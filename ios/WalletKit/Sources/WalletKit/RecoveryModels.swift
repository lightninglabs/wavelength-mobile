import Foundation

public struct RefreshResult: Decodable, Sendable {
    public let queuedOutpoints: [String]?
    public let dryRun: Bool
    public let feeEstimate: RefreshFeeEstimate?
    enum CodingKeys: String, CodingKey {
        case queuedOutpoints = "QueuedOutpoints", dryRun = "DryRun", feeEstimate = "FeeEstimate"
    }
}

public struct RefreshFeeEstimate: Decodable, Sendable {
    public let totalFeeSat: Int64?
    public let freeRefreshEligible: Bool
    public let estimateError: String
    enum CodingKeys: String, CodingKey {
        case totalFeeSat = "TotalFeeSat", freeRefreshEligible = "FreeRefreshEligible", estimateError = "EstimateError"
    }
}

public struct ExitPlan: Decodable, Sendable {
    public let plans: [ExitPlanEntry]?
    public let canStart: Bool
    public let totalFundingShortfallSat: Int64
    public let totalRecommendedFundingSat: Int64
    enum CodingKeys: String, CodingKey {
        case plans = "Plans", canStart = "CanStart"
        case totalFundingShortfallSat = "TotalFundingShortfallSat"
        case totalRecommendedFundingSat = "TotalRecommendedFundingSat"
    }
}

public struct ExitPlanEntry: Decodable, Sendable {
    public let outpoint: String
    public let fundingAddress: String
    public let requiredConfirmations: UInt32
    public let requiredFeeUTXOCount: UInt32
    public let usableFeeUTXOCount: UInt32
    public let recommendedUTXOAmountSat: Int64
    public let fundingShortfallSat: Int64
    public let canStart: Bool
    public let infeasibilityReason: String
    public let exitJobFound: Bool
    public let exitStatus: String
    public let lastError: String
    public let roundCommitment: String
    public let error: String
    enum CodingKeys: String, CodingKey {
        case outpoint = "Outpoint", fundingAddress = "FundingAddress"
        case requiredConfirmations = "RequiredConfirmations", requiredFeeUTXOCount = "RequiredFeeUTXOCount"
        case usableFeeUTXOCount = "UsableFeeUTXOCount", recommendedUTXOAmountSat = "RecommendedUTXOAmountSat"
        case fundingShortfallSat = "FundingShortfallSat", canStart = "CanStart"
        case infeasibilityReason = "InfeasibilityReason", exitJobFound = "ExitJobFound"
        case exitStatus = "ExitStatus", lastError = "LastError", roundCommitment = "RoundCommitment", error = "Err"
    }
}

public struct ExitProgress: Decodable, Sendable {
    public let confirmedTxs: UInt32
    public let inFlightTxs: UInt32
    public let blockedTxs: UInt32
    public let totalTxs: UInt32
    enum CodingKeys: String, CodingKey {
        case confirmedTxs = "ConfirmedTxs", inFlightTxs = "InFlightTxs"
        case blockedTxs = "BlockedTxs", totalTxs = "TotalTxs"
    }
}

public struct ExitCSV: Decodable, Sendable {
    public let blocksRemaining: Int32
    public let mature: Bool
    enum CodingKeys: String, CodingKey { case blocksRemaining = "BlocksRemaining", mature = "Mature" }
}

public struct ExitFees: Decodable, Sendable {
    public let cpfpFeeSat: Int64
    public let sweepFeeSat: Int64
    public let totalCostSat: Int64
    public let spentSoFarSat: Int64
    public let netRecoveredSat: Int64
    public let sweepFeeActual: Bool
    enum CodingKeys: String, CodingKey {
        case cpfpFeeSat = "CPFPFeeSat", sweepFeeSat = "SweepFeeSat", totalCostSat = "TotalCostSat"
        case spentSoFarSat = "SpentSoFarSat", netRecoveredSat = "NetRecoveredSat", sweepFeeActual = "SweepFeeActual"
    }
}

public struct ExitSummary: Decodable, Sendable {
    public let exits: [ExitSummaryEntry]?
    enum CodingKeys: String, CodingKey { case exits = "Exits" }
}

public struct ExitSummaryEntry: Decodable, Identifiable, Sendable {
    public var id: String { outpoint }
    public let outpoint: String
    public let status: String
    public let vtxoAmountSat: Int64
    enum CodingKeys: String, CodingKey {
        case outpoint = "Outpoint", status = "Status", vtxoAmountSat = "VTXOAmountSat"
    }
}

public struct SweepPreview: Decodable, Sendable {
    public let totalInputSat: Int64
    public let estimatedFeeSat: Int64
    public let netAmountSat: Int64
    public let canBroadcast: Bool
    public let txid: String
    public let failureReason: String
    enum CodingKeys: String, CodingKey {
        case totalInputSat = "TotalInputSat", estimatedFeeSat = "EstimatedFeeSat", netAmountSat = "NetAmountSat"
        case canBroadcast = "CanBroadcast", txid = "Txid", failureReason = "FailureReason"
    }
}

public struct RefreshObservation: Decodable, Sendable {
    public let complete: Bool
    public let retryAllowed: Bool?
    enum CodingKeys: String, CodingKey { case complete = "Complete", retryAllowed = "RetryAllowed" }
}
