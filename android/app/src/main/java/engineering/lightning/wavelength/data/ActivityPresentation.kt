package engineering.lightning.wavelength.data

import engineering.lightning.wavewalletdk.client.Entry
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.LocalDate
import java.time.format.DateTimeFormatter

fun sats(amount: Long): String = "${NumberFormat.getIntegerInstance().format(amount)} sats"
val Entry.incoming: Boolean get() = kind == "receive" || kind == "deposit"
val Entry.creditTopup: Boolean get() = kind == "send" && progress?.phaseLabel == "credit_topup"
val Entry.paymentHash: String get() = progress?.paymentHash?.ifEmpty { null } ?: request?.paymentHash.orEmpty()
val Entry.rail: String get() = when (request?.type?.lowercase()) {
  "ark" -> "Ark"
  "onchain" -> "On-chain"
  "lightning" -> "Lightning"
  else -> when {
    kind == "receive" || paymentHash.isNotEmpty() -> "Lightning"
    kind == "exit" || kind == "deposit" -> "On-chain"
    else -> "Not reported"
  }
}
private val Entry.pendingLightningStatus: String? get() {
  if (kind != "receive" || status != "pending" || rail != "Lightning" || (request == null && paymentHash.isEmpty())) return null
  val phase = progress?.phase.orEmpty().takeUnless { it.isEmpty() || it == "unspecified" } ?: progress?.phaseLabel.orEmpty()
  return when (phase) {
    "request_created", "waiting_for_payment" -> "Waiting for payment"
    "awaiting_funding" -> "Awaiting funding"
    "settling" -> if (progress?.vtxoOutpoint.isNullOrEmpty()) "Checking status" else "Receiving"
    else -> "Checking status"
  }
}
val Entry.showsProgress: Boolean get() = status == "pending" && (pendingLightningStatus?.let { it == "Receiving" } ?: !awaitingPayment)
val Entry.awaitingPayment: Boolean get() {
  pendingLightningStatus?.let { return it == "Waiting for payment" }
  val phase = progress?.phaseLabel?.ifEmpty { null } ?: progress?.phase.orEmpty()
  return incoming && status == "pending" && phase in listOf("", "request_created", "waiting_for_payment", "address_issued", "unspecified")
}
val Entry.statusLabel: String get() = when {
  failureCode == "needs_intervention" -> "Action needed"
  progress?.phase == "refunding" -> "Refunding"
  failureCode == "refunded" || progress?.phase == "refunded" -> "Refunded"
  kind == "receive" && failureCode == "expired" -> "Expired"
  status == "failed" -> "Failed"
  pendingLightningStatus != null -> pendingLightningStatus!!
  awaitingPayment -> "Waiting for payment"
  status == "pending" -> if (incoming) "Receiving" else if (kind == "send") "Sending" else "In progress"
  status == "complete" -> if (incoming) "Received" else if (kind == "send") "Sent" else "Complete"
  else -> "Checking status"
}
val Entry.title: String get() = when {
  creditTopup -> "Credit top-up"
  note.isNotBlank() -> note
  kind == "send" -> "Payment"
  incoming -> "Bitcoin"
  kind == "exit" -> "Exit"
  kind == "refresh" -> "Refresh"
  else -> kind.replaceFirstChar { it.uppercase() }
}
fun visibleActivity(entries: List<Entry>): List<Entry> {
  val hashes = entries.filter { it.kind == "send" && !it.creditTopup }.map { it.paymentHash }.filter { it.isNotEmpty() }.toSet()
  return entries.filterNot { it.creditTopup && it.status != "failed" && it.paymentHash.isNotEmpty() && it.paymentHash in hashes }
}
fun activityTime(value: String): String = runCatching {
  val zone = ZoneId.systemDefault()
  val instant = Instant.parse(value)
  val pattern = if (instant.atZone(zone).toLocalDate() == LocalDate.now(zone)) "HH:mm" else "MMM d, HH:mm"
  DateTimeFormatter.ofPattern(pattern).withZone(zone).format(instant)
}.getOrDefault("")
