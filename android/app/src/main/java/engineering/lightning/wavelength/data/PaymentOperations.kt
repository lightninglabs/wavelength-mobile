package engineering.lightning.wavelength.data

import android.util.AtomicFile
import engineering.lightning.wavewalletdk.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.nullable
import kotlinx.serialization.json.Json
import java.io.File
import java.time.Instant

@Serializable
data class PendingPayment(
  val kind: String,
  val amountSat: Long,
  val note: String,
  val startedAt: Long,
  val existingIds: List<String>,
  val intentId: String = "",
  val paymentHash: String = "",
  val requestId: String = "",
  val receiptConsentEpoch: String? = null,
  val destination: String = "",
  val selectedOutpoints: List<String> = emptyList(),
  val balanceSweep: Boolean = false,
  val recipientSat: Long? = null,
) {
  fun matches(entry: Entry): Boolean {
    if (entry.id in existingIds || entry.creditTopup || kotlin.math.abs(entry.amountSat) != amountSat) return false
    val created = runCatching { Instant.parse(entry.createdAt).epochSecond }.getOrNull() ?: return false
    if (created < startedAt) return false
    return when (kind) {
      "send" -> entry.kind in setOf("send", "exit") && (entry.id == intentId ||
        (paymentHash.isNotEmpty() && entry.paymentHash == paymentHash) ||
        (entry.kind == "exit" && destination.isNotEmpty() && entry.request?.onchainAddress == destination &&
          entry.progress?.vtxoOutpoint in selectedOutpoints))
      "receive" -> requestId.isEmpty() && entry.kind == "receive" && entry.note == note && !entry.request?.lightningInvoice.isNullOrBlank()
      else -> false
    }
  }
}

interface PaymentJournal {
  fun read(): PendingPayment?
  fun write(value: PendingPayment?)
}

/** Atomic writes precede native dispatch. Corrupt evidence is never overwritten. */
class FilePaymentJournal(file: File) : PaymentJournal {
  private val file = AtomicFile(file)
  private val json = Json { ignoreUnknownKeys = true }
  override fun read(): PendingPayment? {
    if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
    return json.decodeFromString<PendingPayment?>(file.readFully().toString(Charsets.UTF_8))
  }
  override fun write(value: PendingPayment?) {
    val out = file.startWrite()
    try { out.write(json.encodeToString(PendingPayment.serializer().nullable, value).toByteArray()); file.finishWrite(out) }
    catch (error: Throwable) { file.failWrite(out); throw error }
  }
}

/** Small native boundary, also used to test accepted-but-response-lost dispatch. */
interface PaymentGateway {
  suspend fun entries(): List<Entry>
  suspend fun prepare(terms: SendTerms): PrepareSendResult
  suspend fun send(intentId: String): SendResult
  suspend fun receive(amount: Long, note: String, requestId: String): ReceiveResult
  suspend fun lookupReceive(requestId: String): ReceiveResult?
  suspend fun deposit(): DepositResult
}

class NativePaymentGateway(private val client: WalletClient, private val limits: () -> CreditLimits = { CreditLimits() }) : PaymentGateway {
  override suspend fun entries() = client.list(limit = 1000).activity?.entries ?: error("Activity unavailable")
  override suspend fun prepare(terms: SendTerms) = limits().let {
    val dest = terms.destination
    client.prepareSend(invoice = dest.value.takeIf { dest.lightning }, onchainAddress = dest.value.takeUnless { dest.lightning },
      amountSat = terms.amountSat, note = terms.note, maxFeeSat = terms.maxFeeSat, sweepAll = terms.maximum && !dest.lightning,
      maxAmount = terms.maximum && dest.lightning, maxCreditSat = it.use, maxCreditTopupSat = it.topup)
  }
  override suspend fun send(intentId: String) = client.send(intentId)
  override suspend fun receive(amount: Long, note: String, requestId: String) =
    client.receiveLightning(amount, note, requestId)
  override suspend fun lookupReceive(requestId: String) = client.lookupReceive(requestId)
  override suspend fun deposit() = client.newDepositAddress()
}

data class PaymentUiState(
  val pending: PendingPayment? = null,
  val busy: Boolean = false,
  val blocked: Boolean = false,
  val quote: PrepareSendResult? = null,
  val balanceSweep: Boolean = false,
  val result: Entry? = null,
  val request: String = "",
  val error: String? = null,
)

class PaymentOperations(
  private val scope: CoroutineScope,
  private val gateway: PaymentGateway,
  private val journal: PaymentJournal,
  private val allowed: () -> Boolean,
  private val onEntry: (Entry) -> Unit,
  private val network: WalletNetwork = WalletNetwork.SIGNET,
  private val receiptConsentEpoch: () -> String? = { null },
  private val enroll: (PendingPayment, ReceiveResult) -> Unit = { _, _ -> },
) {
  private val mutable = MutableStateFlow(try { PaymentUiState(pending = journal.read()) }
    catch (_: Exception) { PaymentUiState(blocked = true, error = "Payment tracking is unreadable. Do not send again until it is recovered.") })
  val state = mutable.asStateFlow()

  fun clearPresentation() {
    if (!mutable.value.busy) mutable.update { it.copy(quote = null, result = null, request = "", error = if (it.blocked) it.error else null) }
  }

  fun prepare(rawInvoice: String, note: String, amountSat: Long = 0, maximum: Boolean = false, maxFeeSat: Long = 0) = launch {
    val dest = SendDestination.parse(rawInvoice)
    if (dest.lightning) require(network.acceptsInvoice(dest.value)) { "Use a ${network.title} Lightning invoice." }
    require(!maximum || (amountSat == 0L && dest.requestedSat == null)) { "Use the requested amount." }
    val requested = dest.requestedSat ?: amountSat
    require(requested in 0..MAX_SAT && maxFeeSat in 0..MAX_SAT && (dest.lightning || maximum || requested > 0)) { "Enter an amount in sats." }
    val quote = gateway.prepare(SendTerms(dest, requested, maximum, maxFeeSat, note.trim()))
    mutable.update { it.copy(quote = quote, balanceSweep = maximum && !dest.lightning, result = null, error = null) }
  }

  fun send() = launch {
    val quote = mutable.value.quote ?: error("Review the payment first.")
    require(quote.expiresAtUnix == 0L || Instant.now().epochSecond < quote.expiresAtUnix) { "Quote expired. Review again." }
    val pending = PendingPayment("send", quote.amountSat, "", Instant.now().epochSecond,
      gateway.entries().map { it.id }, quote.sendIntentId, quote.paymentHash,
      destination = quote.destinationSummary, selectedOutpoints = quote.selectedOutpoints,
      balanceSweep = mutable.value.balanceSweep,
      recipientSat = if (mutable.value.balanceSweep && quote.feeKnown) quote.amountSat - quote.expectedFeeSat else null)
    check(allowed()) { "Unlock this wallet before confirming." }
    persist(pending)
    try {
      val result = gateway.send(quote.sendIntentId)
      onEntry(result.entry)
      mutable.update { it.copy(result = result.entry, quote = null) }
      persist(null)
    } catch (error: Exception) {
      if (error.message?.startsWith("send rejected before dispatch:") == true) persist(null)
      throw error
    }
  }

  fun receive(amount: Long, note: String) = launch {
    require(amount > 0) { "Enter an amount in sats." }
    val pending = PendingPayment("receive", amount, note.trim(), Instant.now().epochSecond, emptyList(),
      requestId = java.util.UUID.randomUUID().toString(), receiptConsentEpoch = receiptConsentEpoch())
    persist(pending)
    finishReceive(pending, gateway.receive(amount, pending.note, pending.requestId))
  }

  private fun finishReceive(pending: PendingPayment, result: ReceiveResult) {
    val warning = try {
      if (pending.receiptConsentEpoch != null && pending.receiptConsentEpoch == receiptConsentEpoch()) {
        enroll(pending, result)
      }
      null
    } catch (error: CancellationException) {
      throw error
    } catch (_: Exception) {
      "Invoice ready. Payment notification enrollment failed."
    }
    onEntry(result.entry)
    persist(null)
    mutable.update { it.copy(result = result.entry, request = result.invoice, error = warning) }
  }

  suspend fun checkPending() {
    val pending = state.value.pending ?: return
    if (state.value.busy || !allowed()) return
    if (pending.requestId.isEmpty()) {
      reconcile(gateway.entries())
      return
    }
    val result = gateway.lookupReceive(pending.requestId)
    if (state.value.pending != pending || state.value.busy || !allowed()) return
    if (result != null) finishReceive(pending, result)
    else {
      persist(null)
      mutable.update { it.copy(error = it.error ?: "No active request was found. Try again.") }
    }
  }

  fun deposit() = launch {
    val result = gateway.deposit()
    mutable.update { it.copy(request = result.address) }
  }

  /** Read-only recovery. Never redispatch an ambiguous operation. */
  fun reconcile(entries: List<Entry>) {
    if (mutable.value.busy || mutable.value.blocked) return
    val pending = mutable.value.pending ?: return
    val match = entries.filter { pending.matches(it) }.singleOrNull() ?: return
    try {
      persist(null)
      onEntry(match)
      mutable.update { it.copy(result = match, quote = null,
        request = if (pending.kind == "receive") match.request?.lightningInvoice.orEmpty() else "", error = null) }
    } catch (error: Exception) { mutable.update { it.copy(error = error.message) } }
  }

  private fun persist(value: PendingPayment?) {
    journal.write(value)
    mutable.update { it.copy(pending = value) }
  }

  private fun launch(action: suspend () -> Unit) {
    if (!allowed() || mutable.value.busy || mutable.value.blocked || mutable.value.pending != null) return
    mutable.update { it.copy(busy = true, error = null) }
    scope.launch {
      try { action() }
      catch (error: CancellationException) { throw error }
      catch (error: Exception) { mutable.update { it.copy(error = error.message ?: "Request failed") } }
      finally {
        mutable.update { it.copy(busy = false) }
        // A response may have been lost after the daemon committed activity.
        runCatching { checkPending() }
      }
    }
  }
}
