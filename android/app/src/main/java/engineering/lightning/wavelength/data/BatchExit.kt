package engineering.lightning.wavelength.data

import engineering.lightning.wavewalletdk.client.*
import java.time.Instant
import kotlinx.serialization.Serializable

@Serializable internal data class ExitInput(val outpoint: String, val sats: Long,
  val state: String = "Checking status", val entryId: String = "", val error: String = "") {
  val pending get() = state == "Checking status" || state == "Exiting"
}
@Serializable internal data class BatchExit(val inputs: List<ExitInput>, val destination: String,
  val baseline: List<String>, val started: Long, val error: String = "") {
  fun admitted(reply: ExitBatchResult) = copy(destination = reply.destination.ifEmpty { destination }, inputs = inputs.map { input ->
    val row = reply.results.singleOrNull { it.outpoint == input.outpoint } ?: return@map input
    when (row.outcome) {
      "accepted" -> input.copy(state = "Exiting", entryId = reply.activityId)
      "failed" -> input.copy(state = "Not exited", error = row.error)
      else -> input.copy(error = row.error)
    }
  })

  fun reconcile(entries: List<Entry>): BatchExit {
    val fresh = entries.filter { entry -> entry.kind == "exit" && entry.counterparty != "unilateral" &&
      entry.id !in baseline && (destination.isEmpty() || entry.request?.onchainAddress == destination) &&
      (runCatching { Instant.parse(entry.createdAt).epochSecond }.getOrNull() ?: Long.MIN_VALUE) >= started }
    val batch = if (inputs.all { it.state == "Checking status" }) fresh.singleOrNull {
      it.id.startsWith("batch-exit-") && it.progress?.vtxoOutpoint == inputs.first().outpoint &&
        it.amountSat == -inputs.sumOf { input -> input.sats }
    } else null
    return copy(destination = destination.ifEmpty { batch?.request?.onchainAddress.orEmpty() }, inputs = inputs.map { input ->
      if (!input.pending) return@map input
      val entry = when {
        input.entryId.isNotEmpty() -> entries.singleOrNull { it.kind == "exit" && it.id == input.entryId }
        batch != null -> batch
        else -> fresh.singleOrNull { it.amountSat == -input.sats && it.progress?.vtxoOutpoint == input.outpoint }
      } ?: return@map input
      input.copy(entryId = entry.id, error = entry.failureReason, state = when (entry.status) {
        "complete" -> "Exited"
        "failed" -> "Not exited"
        else -> "Exiting"
      })
    })
  }
}

internal fun exitFee(fund: WalletVTXO, estimate: ExitFeeEstimate): Long {
  require(fund.outpoint == estimate.outpoint && fund.amountSat == estimate.amountSat) { "Selected funds changed. Review again." }
  require(!estimate.belowDust && estimate.estimatedFeeSat in 0 until fund.amountSat) { "Selected funds are too small to exit at this fee." }
  return estimate.estimatedFeeSat
}
