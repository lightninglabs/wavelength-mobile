package engineering.lightning.wavewalletdk.client

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable data class ExitPlan(
  @SerialName("Plans") val plans: List<ExitPlanEntry> = emptyList(),
  @SerialName("CanStart") val canStart: Boolean,
  @SerialName("TotalFundingShortfallSat") val totalFundingShortfallSat: Long,
  @SerialName("TotalRecommendedFundingSat") val totalRecommendedFundingSat: Long,
)

@Serializable data class ExitPlanEntry(
  @SerialName("Outpoint") val outpoint: String,
  @SerialName("FundingAddress") val fundingAddress: String,
  @SerialName("RequiredConfirmations") val requiredConfirmations: Long,
  @SerialName("RequiredFeeUTXOCount") val requiredFeeUTXOCount: Long,
  @SerialName("UsableFeeUTXOCount") val usableFeeUTXOCount: Long,
  @SerialName("RecommendedUTXOAmountSat") val recommendedUTXOAmountSat: Long,
  @SerialName("FundingShortfallSat") val fundingShortfallSat: Long,
  @SerialName("CanStart") val canStart: Boolean,
  @SerialName("InfeasibilityReason") val infeasibilityReason: String,
  @SerialName("ExitJobFound") val exitJobFound: Boolean,
  @SerialName("ExitStatus") val exitStatus: String,
  @SerialName("LastError") val lastError: String,
  @SerialName("RoundCommitment") val roundCommitment: String,
  @SerialName("Err") val error: String,
)

@Serializable data class ExitProgress(
  @SerialName("ConfirmedTxs") val confirmedTxs: Long,
  @SerialName("InFlightTxs") val inFlightTxs: Long,
  @SerialName("BlockedTxs") val blockedTxs: Long,
  @SerialName("TotalTxs") val totalTxs: Long,
)

@Serializable data class ExitCSV(
  @SerialName("BlocksRemaining") val blocksRemaining: Int,
  @SerialName("Mature") val mature: Boolean,
)

@Serializable data class ExitFees(
  @SerialName("CPFPFeeSat") val cpfpFeeSat: Long,
  @SerialName("SweepFeeSat") val sweepFeeSat: Long,
  @SerialName("TotalCostSat") val totalCostSat: Long,
  @SerialName("SpentSoFarSat") val spentSoFarSat: Long,
  @SerialName("NetRecoveredSat") val netRecoveredSat: Long,
  @SerialName("SweepFeeActual") val sweepFeeActual: Boolean,
)

@Serializable data class ExitSummary(
  @SerialName("Exits") val exits: List<ExitSummaryEntry> = emptyList(),
)

@Serializable data class ExitSummaryEntry(
  @SerialName("Outpoint") val outpoint: String,
  @SerialName("Status") val status: String,
  @SerialName("VTXOAmountSat") val vtxoAmountSat: Long,
)

@Serializable data class SweepPreview(
  @SerialName("TotalInputSat") val totalInputSat: Long,
  @SerialName("EstimatedFeeSat") val estimatedFeeSat: Long,
  @SerialName("NetAmountSat") val netAmountSat: Long,
  @SerialName("FeeRateSatPerVByte") val feeRateSatPerVByte: Long,
  @SerialName("CanBroadcast") val canBroadcast: Boolean,
  @SerialName("Txid") val txid: String,
  @SerialName("FailureReason") val failureReason: String,
)
