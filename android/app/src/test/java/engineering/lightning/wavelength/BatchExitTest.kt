package engineering.lightning.wavelength

import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.*
import org.junit.Assert.*
import org.junit.Test

class BatchExitTest {
  private val pending = BatchExit(listOf(ExitInput("a:0", 900), ExitInput("b:1", 600)), "address", listOf("old"), 100)
  private fun entry(id: String, amount: Long) = Entry(id, "exit", "complete", amount,
    createdAt = "2025-01-01T00:00:00Z", request = EntryRequest(onchainAddress = "address"),
    progress = EntryProgress(vtxoOutpoint = "a:0"))

  @Test fun lostBatchReplyRequiresUniqueNewEvidenceForFullSelection() {
    assertEquals(pending, pending.reconcile(listOf(entry("old", -1500), entry("batch-exit-new", -700))))
    assertTrue(pending.reconcile(listOf(entry("batch-exit-new", -1500))).inputs.all { it.state == "Exited" })
  }

  @Test fun partialAdmissionOnlyAssignsActivityToAcceptedInputs() {
    val partial = pending.admitted(ExitBatchResult(listOf(ExitBatchInput("a:0", "accepted")), activityId = "batch-exit-new"))
    val checked = partial.reconcile(listOf(entry("batch-exit-new", -900)))
    assertEquals(listOf("Exited", "Checking status"), checked.inputs.map { it.state })
  }

  @Test fun estimateMustCoverSameFundsAndLeaveSpendableOutput() {
    val fund = WalletVTXO("a:0", 1000)
    val estimate = ExitFeeEstimate("a:0", 1000, 75, false)
    assertEquals(75L, exitFee(fund, estimate))
    assertTrue(runCatching { exitFee(fund, estimate.copy(belowDust = true)) }.isFailure)
    assertTrue(runCatching { exitFee(fund, estimate.copy(outpoint = "b:1")) }.isFailure)
  }
}
