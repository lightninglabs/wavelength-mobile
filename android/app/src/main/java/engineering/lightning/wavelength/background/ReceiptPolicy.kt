package engineering.lightning.wavelength.background

import engineering.lightning.wavewalletdk.client.LightningReceipt
import engineering.lightning.wavewalletdk.client.ReceiptReference
import kotlinx.serialization.Serializable

@Serializable data class ReceiptConsent(val epoch: String, val since: Long, val identity: String,
  val connection: String, val amounts: Boolean = false)
@Serializable data class EnrolledReceipt(val network: String, val consent: ReceiptConsent,
  val reference: ReceiptReference, val canonicalId: String, val amountSat: Long, val enrolledAt: Long,
  val claimed: Boolean = false)

/** A remote payload never contributes any term to amount authority. */
fun receiptMatches(enrolled: EnrolledReceipt, consent: ReceiptConsent?, proof: LightningReceipt): Boolean =
  consent == enrolled.consent && !enrolled.claimed && proof.reference == enrolled.reference &&
    proof.canonicalId.isNotEmpty() && proof.canonicalId == enrolled.canonicalId && proof.state == "complete" &&
    proof.amountSat > 0 && proof.amountSat == enrolled.amountSat && proof.createdAtUnix > enrolled.consent.since

@Serializable data class RelayRoute(val id: String, val network: String, val identity: String,
  val connection: String, val expiresAt: Long)
data class PushHint(val routeId: String, val kind: String, val eventId: String) {
  companion object {
    fun parse(data: Map<String,String>): PushHint? {
      if (data["version"] != "1") return null
      val route = data["route_id"] ?: return null
      val kind = data["kind"] ?: return null
      if (!Regex("[A-Za-z0-9_.-]{1,100}").matches(route) || kind !in setOf("wake", "payment_activity")) return null
      val event = data["event_id"].orEmpty()
      if (kind == "payment_activity" && !Regex("[a-f0-9]{64}").matches(event)) return null
      return PushHint(route,kind,event)
    }
  }
}

fun routeMatches(route: RelayRoute, network: String, identity: String?, connection: String,
  consent: ReceiptConsent?, now: Long) = route.network == network && route.connection == connection &&
  route.expiresAt > now && (identity.isNullOrEmpty() || route.identity == identity) &&
  consent?.identity == route.identity && consent.connection == connection
