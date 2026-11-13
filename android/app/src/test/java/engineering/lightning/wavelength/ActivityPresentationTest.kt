package engineering.lightning.wavelength

import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.*
import org.junit.Assert.*
import org.junit.Test

class ActivityPresentationTest {
  @Test fun creditFundingOnlyDisappearsWhenItsPaymentIsPresent() {
    val funding = Entry(id = "funding", kind = "send", status = "complete", progress = EntryProgress(phaseLabel = "credit_topup", paymentHash = "hash"))
    val payment = Entry(id = "payment", kind = "send", status = "complete", request = EntryRequest(paymentHash = "hash"))
    assertEquals(listOf(funding), visibleActivity(listOf(funding)))
    assertEquals(listOf(payment), visibleActivity(listOf(funding, payment)))
    assertEquals(2, visibleActivity(listOf(funding.copy(status = "failed"), payment)).size)
  }
  @Test fun pendingInvoiceAndIncomingFundsHaveDifferentStatuses() {
    val entry = Entry(kind = "receive", status = "pending", progress = EntryProgress(phase = "waiting_for_payment"))
    assertEquals("Waiting for payment", entry.statusLabel)
    assertEquals("Receiving", entry.copy(progress = EntryProgress(phase = "settling")).statusLabel)
    assertEquals("Received", entry.copy(status = "complete").statusLabel)
    assertEquals("Expired", entry.copy(status = "failed", failureCode = "expired").statusLabel)
  }
}
