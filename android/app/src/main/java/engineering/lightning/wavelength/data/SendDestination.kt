package engineering.lightning.wavelength.data

import java.math.BigDecimal
import java.net.URLDecoder

internal const val MAX_SAT = 2_100_000_000_000_000L

internal fun wholeSats(text: String): Long? =
  text.takeIf { it.isNotEmpty() && it.all { digit -> digit in '0'..'9' } }
    ?.toLongOrNull()?.takeIf { it in 1..MAX_SAT }

data class SendDestination(val value: String, val lightning: Boolean, val requestedSat: Long? = null) {
  companion object {
    fun parse(raw: String): SendDestination {
      val trimmed = raw.trim()
      fun decode(value: String) = URLDecoder.decode(value.replace("+", "%2B"), "UTF-8")
      fun lightning(value: String): SendDestination {
        val invoice = if (value.startsWith("lightning:", true)) value.substringAfter(':').removePrefix("//") else value
        require(invoice.startsWith("ln", true)) { "Invalid Lightning invoice." }
        return SendDestination(invoice, true)
      }
      if (trimmed.startsWith("lightning:", true)) return lightning(decode(trimmed))
      if (trimmed.startsWith("ln", true)) return lightning(trimmed)
      if (!trimmed.startsWith("bitcoin:", true)) {
        require(trimmed.isNotBlank() && ':' !in trimmed) { "Enter a Bitcoin address or Lightning invoice." }
        return SendDestination(trimmed, false)
      }
      val target = trimmed.substringAfter(':').removePrefix("//")
      val params = target.substringAfter('?', "").split('&').filter { it.isNotEmpty() }
        .groupBy({ decode(it.substringBefore('=')).lowercase() }, { decode(it.substringAfter('=', "")) })
      require(params.keys.none { it.startsWith("req-") }) { "Unsupported required Bitcoin payment option." }
      require(listOf("amount", "lightning").none { (params[it]?.size ?: 0) > 1 }) { "Conflicting Bitcoin payment options." }
      params["lightning"]?.single()?.let { return lightning(it) }
      val address = decode(target.substringBefore('?'))
      require(address.isNotBlank()) { "Missing Bitcoin address." }
      val sats = params["amount"]?.single()?.let { amount ->
        require(Regex("[0-9]{1,8}(\\.[0-9]{1,8})?").matches(amount)) { "Invalid Bitcoin amount." }
        BigDecimal(amount).movePointRight(8).longValueExact().also {
          require(it in 1..MAX_SAT) { "Invalid Bitcoin amount." }
        }
      }
      return SendDestination(address, false, sats)
    }
  }
}

data class SendTerms(val destination: SendDestination, val amountSat: Long, val maximum: Boolean,
  val maxFeeSat: Long, val note: String)

internal fun paymentFailure(raw: String): String {
  val reason = raw.lowercase()
  return when {
    "maximum payment quote changed" in reason -> "The quote changed. Calculate the available balance again."
    "change below minimum" in reason -> "This amount would leave too little change. Request a different amount or add funds."
    "insufficient spendable funds" in reason || "insufficient funds" in reason -> "There isn’t enough available balance for the payment and its fees."
    "invoice amount is required" in reason -> "Ask the recipient for an invoice with an amount. This payment service requires one."
    "already paid" in reason || "already been paid" in reason -> "This invoice has already been paid. Ask for a new invoice."
    "invoice has expired" in reason || "invoice is expired" in reason -> "This invoice has expired. Ask for a new invoice."
    "rpc error:" !in reason -> raw
    "code = unavailable" in reason -> "The payment service is unavailable. Check your connection and Activity before trying again."
    "code = invalidargument" in reason || "code = failedprecondition" in reason -> "Review the invoice, amount and fees."
    else -> "The result could not be confirmed. Check Activity before trying again."
  }
}
