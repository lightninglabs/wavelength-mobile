package engineering.lightning.wavelength

import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.*
import kotlinx.coroutines.runBlocking
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

  @Test fun closedRequestReleasesInputsEvenWithoutActivity() = runBlocking {
    val attempt = pending.copy(requestId = "request")
    val recovered = attempt.recover { id -> assertEquals("request", id); null }
    assertTrue(recovered.inputs.all { it.state == "Not exited" })
  }

  @Test fun lostReplyUsesOnlyTheReceiptAndKeepsTheOriginalActivityId() = runBlocking {
    val attempt = pending.copy(requestId = "request")
    val unrelated = entry("batch-exit-unrelated", -1500)
    assertEquals(attempt, attempt.reconcile(listOf(unrelated)))
    assertThrows(IllegalStateException::class.java) {
      runBlocking { attempt.recover { error("wallet offline") } }
    }
    val receipt = ExitBatchResult(listOf(ExitBatchInput("a:0", "accepted"), ExitBatchInput("b:1", "failed")),
      activityId = "batch-exit-original")
    val recovered = attempt.recover { receipt }.reconcile(listOf(unrelated))
    assertEquals(listOf("Exiting", "Not exited"), recovered.inputs.map { it.state })
    assertEquals("Exited", recovered.reconcile(listOf(entry("batch-exit-original", -900))).inputs.first().state)
  }

  @Test fun estimateMustCoverSameFundsAndLeaveSpendableOutput() {
    val fund = WalletVTXO("a:0", 1000)
    val estimate = ExitFeeEstimate("a:0", 1000, 75, false)
    assertEquals(75L, exitFee(fund, estimate))
    assertTrue(runCatching { exitFee(fund, estimate.copy(belowDust = true)) }.isFailure)
    assertTrue(runCatching { exitFee(fund, estimate.copy(outpoint = "b:1")) }.isFailure)
  }
}
