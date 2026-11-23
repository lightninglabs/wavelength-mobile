package engineering.lightning.wavelength.data

import engineering.lightning.wavewalletdk.client.DiagnosticLog
import kotlinx.serialization.json.*
import java.util.Locale

operator fun JsonElement.get(key: String): JsonElement = (this as? JsonObject)?.get(key) ?: JsonNull
val JsonElement.text: String get() = (this as? JsonPrimitive)?.contentOrNull.orEmpty()
val JsonElement.number: Long get() = text.toLongOrNull() ?: 0
val JsonElement.items: List<JsonElement> get() = (this as? JsonArray)?.toList().orEmpty()
val JsonElement.fields: Map<String, JsonElement> get() = (this as? JsonObject).orEmpty()
private val prettyJson = Json { prettyPrint = true }
val JsonElement.pretty: String get() = prettyJson.encodeToString(JsonElement.serializer(), this)
fun shortId(value: String) = if (value.length > 26) "${value.take(12)}…${value.takeLast(10)}" else value
fun diagnosticLabel(value: String): String {
  if (value == "failed_before_ponr") return "Failed before funds were committed"
  val cleaned = value.replace(Regex("^(VTXO_EXPIRY_STATUS_|VTXO_STATUS_|WALLET_STATE_|ROUND_STATE_|SWAP_STATE_|CREDIT_OPERATION_STATE_)"), "")
  return cleaned.lowercase(Locale.ROOT).replace('_', ' ').replaceFirstChar(Char::titlecase)
}
fun expiryLabel(value: JsonElement): String = when {
  value["status"].text == "VTXO_EXPIRY_STATUS_UNKNOWN" || value["batch_expiry"].number <= 0 || value["current_height"].number <= 0 -> "Expiry unknown"
  value["blocks_remaining"].number > 0 -> "${value["blocks_remaining"].number} blocks left"
  else -> "Expired"
}
fun refreshDue(value: JsonElement) = value["status"].text in setOf(
  "VTXO_EXPIRY_STATUS_NEEDS_REFRESH", "VTXO_EXPIRY_STATUS_CRITICAL", "VTXO_EXPIRY_STATUS_EXPIRED")

data class ExpiryWindow(val current: Long, val expiry: Long, val refresh: Long, val critical: Long) {
  companion object {
    fun from(value: JsonElement): ExpiryWindow? {
      val current = value["current_height"].number; val expiry = value["batch_expiry"].number
      val refresh = value["refresh_threshold_blocks"].number; val critical = value["critical_threshold_blocks"].number
      return if (minOf(current, expiry, refresh, critical) > 0) ExpiryWindow(current, expiry, expiry - refresh, expiry - critical) else null
    }
  }
}
fun transferDirection(value: JsonElement): String = when (value["direction"].text) {
  "OOR_SESSION_DIRECTION_OUTGOING", "SWAP_DIRECTION_PAY" -> "Outgoing"
  "OOR_SESSION_DIRECTION_INCOMING", "SWAP_DIRECTION_RECEIVE" -> "Incoming"
  else -> when (value["type"].text) {
    "CREDIT_OPERATION_TYPE_FUNDING" -> "To credit"
    "CREDIT_OPERATION_TYPE_REDEMPTION" -> "From credit"
    "CREDIT_OPERATION_TYPE_PAY" -> "Outgoing"
    "CREDIT_OPERATION_TYPE_RECEIVE" -> "Incoming"
    else -> "Direction unknown"
  }
}

/** Freeze the displayed buffer while browsing so native eviction cannot move it. */
class DiagnosticLogWindow {
  var following = true; private set
  private var frozen: List<DiagnosticLog>? = null
  fun records(live: List<DiagnosticLog>) = frozen ?: live
  fun browse(live: List<DiagnosticLog>) { if (following) { frozen = live.toList(); following = false } }
  fun follow() { frozen = null; following = true }
}

fun DiagnosticLog.inTimeWindow(since: Long?, until: Long?) =
  (since == null || time >= since) && (until == null || time <= until)

internal data class TransferSummary(val title: String, val amount: String?, val status: String,
  val failure: String = "", val recoveryPackage: Boolean = false, val relatedSwap: JsonElement = JsonNull)

internal fun transferSummary(rail: String, item: JsonElement, ledger: List<JsonElement>): TransferSummary {
  val diagnostic = item["diagnostic"]
  val amount = item["amount_sat"].number.takeIf { it > 0 }?.let(::sats)
  val unavailable = if (diagnostic["amount_read_failed"].text == "true") "Amount could not be read" else "Amount unavailable"
  val state = diagnosticLabel(item["state"].text)
  if (rail == "Credit") {
    val title = when (item["type"].text.removePrefix("CREDIT_OPERATION_TYPE_")) {
      "FUNDING" -> "Credit funding"
      "REDEMPTION" -> "Credit redemption"
      "PAY" -> "Credit payment"
      "RECEIVE" -> "Credit attached to receive"
      else -> "Credit operation"
    }
    val rawState = item["state"].text.removePrefix("CREDIT_OPERATION_STATE_")
    val direction = if (rawState == "CREDITED") "credit" else "debit"
    val id = item["operation_id"].text
    val posted = if (id.isNotEmpty() && rawState in setOf("CREDITED", "DEBITED", "REDEEMED")) ledger.singleOrNull {
      it["operation_id"].text == id && it["direction"].text == direction
    }?.get("amount_sat")?.number?.takeIf { it > 0 } else null
    return TransferSummary(title, posted?.let { "Posted · ${sats(it)}" } ?: amount?.let { "Operation amount · $it" } ?: unavailable,
      state, item["last_error"].text)
  }
  if (rail == "Lightning") return TransferSummary(transferDirection(item), amount ?: unavailable, state, item["terminal_reason"].text)
  val status = diagnosticLabel(item["phase"].text.ifEmpty { item["status"].text.removePrefix("OOR_SESSION_STATUS_") })
  val failure = item["failure_reason"].text
  if (item["status"].text == "OOR_SESSION_STATUS_COMPLETED" && failure.isEmpty()) {
    when (diagnostic["kind"].text) {
      "recovery_package" -> return TransferSummary("Ark recovery package", null, "Kept for wallet recovery", recoveryPackage = true)
      "stored_package" -> return TransferSummary("Stored Ark package", amount ?: unavailable, "Wallet relationship unknown")
      "lightning_receive_claim" -> {
        val claimed = diagnostic["claimed_amount_sat"].number
        val claimAmount = when {
          claimed > 0 -> "Claimed to wallet · ${sats(claimed)}"
          diagnostic["claimed_amount_read_failed"].text == "true" -> "Amount could not be read"
          else -> "Amount unavailable"
        }
        return TransferSummary("Lightning receive claim", claimAmount, status, relatedSwap =
          diagnostic["related_swap"].takeIf { it["payment_hash"].text.isNotBlank() } ?: JsonNull)
      }
    }
  }
  return TransferSummary(transferDirection(item), amount ?: unavailable, status, failure)
}
