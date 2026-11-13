package engineering.lightning.wavelength.background

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.AtomicFile
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import engineering.lightning.wavelength.MainActivity
import engineering.lightning.wavelength.R
import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

@Serializable private data class ReceiptState(val consent: Map<String, ReceiptConsent> = emptyMap(), val enrolled: List<EnrolledReceipt> = emptyList(), val nextRead: Map<String,Int> = emptyMap())

/** Main-thread owned, device-only local receipt admissions and presentation claims. */
class WalletNotices(private val context: Context) {
  private val file = AtomicFile(File(context.noBackupFilesDir,"notification-receipts.json"))
  private val json = Json { ignoreUnknownKeys = true }
  private var unreadable = false
  private var value = try {
    if (file.baseFile.exists() || java.io.File(file.baseFile.path + ".bak").exists()) json.decodeFromString<ReceiptState>(file.readFully().toString(Charsets.UTF_8)) else ReceiptState()
  } catch (_: Exception) { unreadable = true; ReceiptState() }
  var revision = kotlinx.coroutines.flow.MutableStateFlow(0); private set
  private fun now() = System.currentTimeMillis()/1000
  fun consent(network: WalletNetwork) = value.consent[network.wire]
  fun allowedBySystem() = (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context,Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) && NotificationManagerCompat.from(context).areNotificationsEnabled()
  private fun save(next: ReceiptState) {
    check(!unreadable) { "Notification history is unreadable. Existing receipt evidence was preserved." }
    val bounded = next.copy(enrolled = next.enrolled.filter { now()-it.enrolledAt < 2*24*3600 }.takeLast(256))
    val out = file.startWrite()
    try { out.write(json.encodeToString(ReceiptState.serializer(),bounded).toByteArray());file.finishWrite(out) }
    catch (error: Throwable) { file.failWrite(out); throw error }
    value = bounded; revision.value++
  }
  fun configure(network: WalletNetwork, identity: String, connection: String, enabled: Boolean, amounts: Boolean = false) {
    check(identity.isNotBlank()) { "Wait for the wallet identity." }
    val consent = value.consent.toMutableMap()
    if (enabled) consent[network.wire] = ReceiptConsent(UUID.randomUUID().toString(),now(),identity,connection,amounts) else consent.remove(network.wire)
    save(value.copy(consent = consent, enrolled = value.enrolled.filterNot { it.network == network.wire }))
  }
  /** Capture consent before invoice dispatch; a later opt-in cannot enroll it. */
  fun admission(network: WalletNetwork, identity: String, connection: String, expectedAmount: Long): ((ReceiveResult) -> Unit)? {
    val consent = consent(network)?.takeIf { it.identity == identity && it.connection == connection } ?: return null
    return { result ->
      val reference = result.receiptReference
      if (consent(network) == consent && reference?.supported == true && result.entry.id.isNotEmpty() && expectedAmount > 0 && result.entry.amountSat == expectedAmount) {
        val enrollment = EnrolledReceipt(network.wire,consent,reference,result.entry.id,result.entry.amountSat,now())
        // A full ledger stops enrolling; never evict a live obligation for a new one.
        val kept = value.enrolled.filter { now()-it.enrolledAt < 2*24*3600 }
        if (kept.size < 256) save(value.copy(enrolled = kept.filterNot { it.network == network.wire && it.reference == reference } + enrollment))
      }
    }
  }
  fun suppressVisible(network: WalletNetwork, canonicalId: String) {
    if (value.enrolled.any { it.network == network.wire && it.canonicalId == canonicalId && !it.claimed })
      save(value.copy(enrolled = value.enrolled.map { if (it.network == network.wire && it.canonicalId == canonicalId) it.copy(claimed = true) else it }))
  }
  fun pending(network: WalletNetwork, identity: String, connection: String): List<EnrolledReceipt> {
    val consent = consent(network)?.takeIf { it.identity == identity && it.connection == connection } ?: return emptyList()
    val pending = value.enrolled.filter { it.network == network.wire && it.consent == consent && !it.claimed && now()-it.enrolledAt < 2*24*3600 }
    if (pending.isEmpty()) return emptyList()
    val start = (value.nextRead[network.wire] ?: 0).mod(pending.size)
    val selected = (pending.drop(start)+pending.take(start)).take(64)
    save(value.copy(nextRead = value.nextRead + (network.wire to (start+selected.size).mod(pending.size))))
    return selected
  }
  fun present(network: WalletNetwork, enrolled: EnrolledReceipt, proof: LightningReceipt, visible: Boolean) {
    if (!receiptMatches(enrolled,consent(network),proof) || !value.enrolled.contains(enrolled)) return
    if (!visible && !allowedBySystem()) return
    // Persist before insertion. A crash may omit an alert; replay cannot duplicate it.
    save(value.copy(enrolled = value.enrolled.map { if (it == enrolled) it.copy(claimed = true) else it }))
    if (visible) return
    val manager = context.getSystemService(NotificationManager::class.java)
    if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(CHANNEL,"Payment activity",NotificationManager.IMPORTANCE_DEFAULT).apply { description = "New locally verified Lightning receipts" })
    val intent = Intent(context,MainActivity::class.java).apply {
      flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
      putExtra("notification_network",network.wire);putExtra("notification_receipt",proof.canonicalId)
      data = android.net.Uri.parse("wavelength-internal://receipt/${network.wire}/${android.net.Uri.encode(proof.canonicalId)}")
    }
    val pending = PendingIntent.getActivity(context,0,intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    val body = if (enrolled.consent.amounts) "You received ${java.text.NumberFormat.getIntegerInstance().format(proof.amountSat)} sats" else "New payment activity"
    val notification = NotificationCompat.Builder(context,CHANNEL).setSmallIcon(R.drawable.ic_notification_wave)
      .setContentTitle("Wavelength").setContentText(body).setContentIntent(pending).setAutoCancel(true)
      .setVisibility(if (enrolled.consent.amounts) NotificationCompat.VISIBILITY_PUBLIC else NotificationCompat.VISIBILITY_PRIVATE)
      .setCategory(NotificationCompat.CATEGORY_STATUS).build()
    runCatching { manager.notify(proof.canonicalId,0,notification) }
  }
  fun knownReceipt(network: WalletNetwork, canonicalId: String) = value.enrolled.any { it.network == network.wire && it.canonicalId == canonicalId && it.claimed }
  companion object { const val CHANNEL = "wavelength.payment-activity.v1" }
}
