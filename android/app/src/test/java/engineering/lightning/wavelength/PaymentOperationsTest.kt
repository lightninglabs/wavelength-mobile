package engineering.lightning.wavelength

import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PaymentOperationsTest {
  private val quote = PrepareSendResult(sendIntentId = "intent", amountSat = 999, paymentHash = "hash")
  private fun accepted() = Entry(id = "payment", kind = "send", status = "complete", amountSat = 999,
    createdAt = "2099-01-01T00:00:00Z", request = EntryRequest(paymentHash = "hash"))
  private class Journal(var value: PendingPayment? = null) : PaymentJournal {
    var failWrite = false
    override fun read() = value
    override fun write(value: PendingPayment?) { check(!failWrite) { "disk full" }; this.value = value }
  }
  private inner class Gateway : PaymentGateway {
    var calls = 0
    var entries = emptyList<Entry>()
    var lostResponse = false
    var receiveError = "receive outcome uncertain"
    var afterDispatch: (() -> Unit)? = null
    override suspend fun entries() = entries
    override suspend fun prepare(invoice: String, note: String) = quote
    override suspend fun send(intentId: String): SendResult {
      calls++; afterDispatch?.invoke()
      if (lostResponse) error("deadline exceeded")
      return SendResult(entry = accepted())
    }
    override suspend fun receive(amount: Long, note: String): ReceiveResult { calls++; error(receiveError) }
    override suspend fun deposit() = DepositResult(address = "tb1...")
  }

  @Test fun failedInitialPersistencePreventsDispatch() = runTest {
    val gateway = Gateway(); val journal = Journal()
    val payments = PaymentOperations(backgroundScope, gateway, journal, { true }, {})
    payments.prepare("lntbs1example", ""); runCurrent()
    journal.failWrite = true
    payments.send(); runCurrent()
    assertEquals(0, gateway.calls)
    assertNull(journal.value)
  }

  @Test fun acceptedButResponseLostSurvivesRestartAndNeverRebroadcasts() = runTest {
    val gateway = Gateway().apply { lostResponse = true }; val journal = Journal()
    val payments = PaymentOperations(backgroundScope, gateway, journal, { true }, {})
    payments.prepare("lntbs1example", ""); runCurrent()
    payments.send(); runCurrent()
    assertNotNull(journal.value)
    payments.send(); runCurrent()
    assertEquals(1, gateway.calls)
    val restarted = PaymentOperations(backgroundScope, gateway, journal, { true }, {})
    val earlier = accepted().copy(id = "old", createdAt = "2020-01-01T00:00:00Z")
    restarted.reconcile(listOf(earlier))
    assertNotNull(journal.value)
    restarted.reconcile(listOf(accepted()))
    assertNull(journal.value)
    assertEquals("payment", restarted.state.value.result?.id)
    assertEquals(1, gateway.calls)
  }

  @Test fun postDispatchDiskFailureRetainsEvidenceUntilReadOnlyRecovery() = runTest {
    val journal = Journal(); val gateway = Gateway().apply { afterDispatch = { journal.failWrite = true } }
    val payments = PaymentOperations(backgroundScope, gateway, journal, { true }, {})
    payments.prepare("lntbs1example", ""); runCurrent()
    payments.send(); runCurrent()
    assertEquals(1, gateway.calls)
    assertNotNull(journal.value)
    journal.failWrite = false
    payments.reconcile(listOf(accepted()))
    assertNull(journal.value)
    assertEquals(1, gateway.calls)
  }

  @Test fun timedOutReceiveRecoversExactRequestWithoutAnotherCreate() = runTest {
    val gateway = Gateway(); val journal = Journal()
    val payments = PaymentOperations(backgroundScope, gateway, journal, { true }, {})
    payments.receive(3200, "Android"); runCurrent()
    assertNotNull(journal.value)
    payments.receive(3200, "Android"); runCurrent()
    assertEquals(1, gateway.calls)
    val entry = Entry(id = "receive", kind = "receive", amountSat = 3200, note = "Android", createdAt = "2099-01-01T00:00:00Z",
      request = EntryRequest(lightningInvoice = "lntbs1original"))
    payments.reconcile(listOf(entry.copy(note = "different")))
    assertNotNull(journal.value)
    payments.reconcile(listOf(entry))
    assertEquals("lntbs1original", payments.state.value.request)
    assertNull(journal.value)
  }

  @Test fun unreadableJournalBlocksEveryNewPayment() = runTest {
    val gateway = Gateway()
    val broken = object : PaymentJournal {
      override fun read(): PendingPayment? = error("corrupt")
      override fun write(value: PendingPayment?) = error("must never overwrite")
    }
    val payments = PaymentOperations(backgroundScope, gateway, broken, { true }, {})
    payments.prepare("lntbs1example", ""); payments.receive(999, ""); runCurrent()
    assertTrue(payments.state.value.blocked)
    assertEquals(0, gateway.calls)
    assertNull(payments.state.value.quote)
  }

  @Test fun lockedSessionCannotStartARequest() = runTest {
    val gateway = Gateway()
    val payments = PaymentOperations(backgroundScope, gateway, Journal(), { false }, {})
    payments.receive(999, ""); runCurrent()
    assertEquals(0, gateway.calls)
  }

  @Test fun ordinaryReceiveRejectionDoesNotPermanentlyBlockTheWallet() = runTest {
    val gateway = Gateway().apply { receiveError = "receive amount exceeds maximum" }
    val journal = Journal()
    val payments = PaymentOperations(backgroundScope, gateway, journal, { true }, {})
    payments.receive(10000000, ""); runCurrent()
    assertNull(journal.value)
    payments.prepare("lntbs1example", ""); runCurrent()
    assertEquals(quote, payments.state.value.quote)
  }
}
