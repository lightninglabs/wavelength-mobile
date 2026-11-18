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
  private val maximum = SendTerms(SendDestination.parse("lntbs1example"), 0, true, 0, "")
  private fun accepted() = Entry(id = "payment", kind = "send", status = "complete", amountSat = 999,
    createdAt = "2099-01-01T00:00:00Z", request = EntryRequest(paymentHash = "hash"))
  private class Journal : PaymentJournal {
    var failWrite = false
    var ledger = PaymentLedger(1)
    val value get() = ledger.pending
    override fun read() = ledger
    override fun write(value: PaymentLedger) { check(!failWrite) { "disk full" }; ledger = value }
  }
  private inner class Gateway : PaymentGateway {
    var calls = 0
    var entries = emptyList<Entry>()
    var lostResponse = false
    var receiveError = "receive outcome uncertain"
    var afterDispatch: (() -> Unit)? = null
    override suspend fun entries() = entries
    var prepared = quote
    override suspend fun prepare(terms: SendTerms) = prepared
    override suspend fun send(intentId: String): SendResult {
      calls++; afterDispatch?.invoke()
      if (lostResponse) error("deadline exceeded")
      return SendResult(entry = accepted())
    }
    var found: ReceiveResult? = null
    var lookupFails = true
    var lookedUpId = ""
    override suspend fun lookupReceive(requestId: String): ReceiveResult? {
      lookedUpId = requestId
      check(!lookupFails)
      return found
    }
    override suspend fun receive(amount: Long, note: String, requestId: String): ReceiveResult { calls++; error(receiveError) }
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
    val payments = PaymentOperations(backgroundScope, gateway, journal, { true }, {}, receiptConsentEpoch = { "original" })
    payments.receive(3200, "Android"); runCurrent()
    assertNotNull(journal.value)
    payments.receive(3200, "Android"); runCurrent()
    assertEquals(1, gateway.calls)
    val entry = Entry(id = "receive", kind = "receive", amountSat = 3200, note = "Android", createdAt = "2099-01-01T00:00:00Z",
      request = EntryRequest(lightningInvoice = "lntbs1original"))
    payments.reconcile(listOf(entry.copy(note = "different")))
    assertNotNull(journal.value)
    payments.reconcile(listOf(entry))
    val requestId = journal.value!!.requestId
    assertEquals(requestId, gateway.lookedUpId)
    gateway.found = ReceiveResult(invoice = "lntbs1original", entry = entry)
    gateway.lookupFails = false
    var enrollments = 0
    val restarted = PaymentOperations(backgroundScope, gateway, journal, { true }, {},
      receiptConsentEpoch = { "original" }, enroll = { pending, result ->
        assertEquals("original", pending.receiptConsentEpoch)
        assertEquals("lntbs1original", result.invoice)
        enrollments++
        throw java.io.IOException("receipt database unavailable")
      })
    restarted.checkPending()
    restarted.checkPending()
    assertEquals(requestId, gateway.lookedUpId)
    assertEquals(1, gateway.calls)
    assertEquals("lntbs1original", restarted.state.value.request)
    assertNull(journal.value)
    assertEquals(1, enrollments)
    assertTrue(restarted.state.value.error.orEmpty().contains("notification"))
  }

  @Test fun recoveredReceiveSkipsEnrollmentAfterConsentChanges() = runTest {
    val gateway = Gateway()
    val journal = Journal()
    val original = PaymentOperations(backgroundScope, gateway, journal, { true }, {},
      receiptConsentEpoch = { "original" })
    original.receive(3200, "Android"); runCurrent()
    assertEquals("original", journal.value?.receiptConsentEpoch)

    gateway.found = ReceiveResult(invoice = "lntbs1original", entry = Entry(id = "receive"))
    gateway.lookupFails = false
    val restarted = PaymentOperations(backgroundScope, gateway, journal, { true }, {},
      receiptConsentEpoch = { "replacement" }, enroll = { _, _ -> fail("Consent changed") })
    restarted.checkPending()
    assertNull(journal.value)
    assertEquals("lntbs1original", restarted.state.value.request)
    assertNull(restarted.state.value.error)
    assertEquals(1, gateway.calls)
  }

  @Test fun separatePaymentRetainsEvidenceAcrossRestartUntilMatched() = runTest {
    val gateway = Gateway().apply { lostResponse = true }
    val journal = Journal()
    val operations = PaymentOperations(backgroundScope, gateway, journal, { true }, {})
    operations.prepare("lntbs1example", ""); runCurrent()
    operations.send(); runCurrent()
    operations.startSeparatePayment()
    assertNotNull(journal.value)
    operations.checkPending()
    operations.startSeparatePayment()
    assertNull(journal.value)
    assertEquals("intent", journal.ledger.unresolved.single().intentId)
    val restarted = PaymentOperations(backgroundScope, gateway, journal, { true }, {})
    gateway.entries = listOf(accepted())
    restarted.checkPending()
    assertTrue(journal.ledger.unresolved.isEmpty())
    assertEquals(1, gateway.calls)
  }

  @Test fun separateSendCannotReuseUnresolvedInvoiceButCanPayADifferentOne() = runTest {
    val gateway = Gateway()
    val original = PendingPayment("send", 999, "", 10, emptyList(), "first", "hash", checks = 2)
    val journal = Journal().apply { ledger = PaymentLedger(2, unresolved = listOf(original)) }
    val payments = PaymentOperations(backgroundScope, gateway, journal, { true }, {})
    payments.prepare("lntbs1example", ""); runCurrent()
    payments.send(); runCurrent()
    assertEquals(0, gateway.calls)
    assertTrue(payments.state.value.error.orEmpty().contains("Payment checks"))
    gateway.prepared = quote.copy(paymentHash = "different")
    payments.prepare("lntbs1other", ""); runCurrent()
    payments.send(); runCurrent()
    assertEquals(1, gateway.calls)
    assertEquals(listOf(original), journal.ledger.unresolved)
  }

  @Test fun oldSameInvoiceAttemptsOnlyResolveFromTheirOwnIntentAcrossRestart() = runTest {
    val a = PendingPayment("send", 999, "", 10, emptyList(), "first", "hash")
    val b = a.copy(intentId = "second")
    fun upgrade(pending: PendingPayment?) = decodePaymentLedger(kotlinx.serialization.json.Json.encodeToString(
      PaymentLedger.serializer(), PaymentLedger(1, pending, listOf(a))))
    val row = accepted().copy(id = "second")
    for (pending in listOf(b, null)) {
      val journal = Journal().apply { ledger = upgrade(pending) }
      fun restart() = PaymentOperations(backgroundScope, Gateway(), journal, { true }, {})
      restart().reconcile(listOf(row, accepted()))
      assertNull(journal.value)
      restart().reconcile(listOf(row, accepted()))
      assertEquals("first", journal.ledger.unresolved.single().intentId)
      restart().reconcile(listOf(row, row.copy(id = "first")))
      assertTrue(journal.ledger.unresolved.isEmpty())
    }
  }

  @Test fun existingPaymentJournalSurvivesUpgrade() {
    assertNull(decodePaymentLedger("null").pending)
    val old = """{"kind":"send","amountSat":125,"note":"","startedAt":10,"existingIds":[],"intentId":"old"}"""
    assertEquals("old", decodePaymentLedger(old).pending?.intentId)
    assertTrue(runCatching { decodePaymentLedger("""{"version":3}""") }.isFailure)
  }

  @Test fun unreadableJournalBlocksEveryNewPayment() = runTest {
    val gateway = Gateway()
    val broken = object : PaymentJournal {
      override fun read(): PaymentLedger = error("corrupt")
      override fun write(value: PaymentLedger) = error("must never overwrite")
    }
    val payments = PaymentOperations(backgroundScope, gateway, broken, { true }, {})
    payments.prepare("lntbs1example", ""); payments.receive(999, ""); runCurrent()
    assertTrue(payments.state.value.blocked)
    assertTrue(runCatching { payments.maximumQuote(maximum) }.exceptionOrNull() is IllegalStateException)
    payments.reviewMaximum(quote)
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
    val gateway = Gateway().apply { receiveError = "receive amount exceeds maximum"; lookupFails = false }
    val journal = Journal()
    val payments = PaymentOperations(backgroundScope, gateway, journal, { true }, {})
    payments.receive(10000000, ""); runCurrent()
    assertNull(journal.value)
    payments.prepare("lntbs1example", ""); runCurrent()
    assertEquals(quote, payments.state.value.quote)
  }

  @Test fun selectedNetworkRejectsAnotherNetworksInvoiceBeforePreparation() = runTest {
    val gateway = Gateway()
    val payments = PaymentOperations(backgroundScope, gateway, Journal(), { true }, {}, WalletNetwork.MAINNET)
    payments.prepare("lntbs1example", ""); runCurrent()
    assertNull(payments.state.value.quote)
    assertTrue(runCatching { payments.maximumQuote(maximum) }.exceptionOrNull() is IllegalArgumentException)
    payments.prepare("lightning:LNBC1EXAMPLE", ""); runCurrent()
    assertEquals(quote, payments.state.value.quote)
  }
}
