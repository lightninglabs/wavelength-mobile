package engineering.lightning.wavelength.background

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import engineering.lightning.wavelength.BuildConfig
import engineering.lightning.wavelength.data.WalletSession

/** Prepared data-only FCM ingress. No sender can supply a native RPC or amount. */
class WalletMessagingService : FirebaseMessagingService() {
  override fun onMessageReceived(message: RemoteMessage) {
    // Do not use FCM notification payloads: Android would display those before
    // local route/consent/proof checks while the process is in the background.
    if (message.notification != null) return
    val hint = PushHint.parse(message.data) ?: return
    // Both service admission and worker entry re-read local authority. No route
    // exists until a publisher's authenticated Android enrollment installs it.
    if (!RelayPushRegistry(this).contains(hint.routeId)) return
    WalletWork.opportunity(this,if (hint.kind == "wake") "Push wake" else "Payment hint",hint.routeId)
  }

}

/** The reference relay currently ships Apple admission only. Fail closed. */
class RelayPushRegistry(context: Context) {
  private val file = android.util.AtomicFile(java.io.File(context.noBackupFilesDir,"notification-relay-routes.json"))
  // Only publisher enrollment may populate this store after authenticated relay
  // admission and wallet-signed source binding. This PR ships no registrar or
  // debug grant writer; a Firebase project alone cannot enroll a route.
  private fun routes(): List<RelayRoute> = runCatching {
    if (!file.baseFile.exists() && !java.io.File(file.baseFile.path + ".bak").exists()) emptyList()
    else kotlinx.serialization.json.Json.decodeFromString<List<RelayRoute>>(file.readFully().toString(Charsets.UTF_8)).take(8)
  }.getOrDefault(emptyList())
  private fun route(id: String) = routes().singleOrNull { it.id == id && it.expiresAt > System.currentTimeMillis()/1000 }
  fun contains(routeId: String) = route(routeId) != null
  fun resolve(routeId: String, wallet: WalletSession): RelayRoute? = route(routeId)?.takeIf {
    val state = wallet.state.value
    val consent = wallet.notices.consent(state.network)
    routeMatches(it,state.network.wire,state.info?.identityPubKey,wallet.connectionFingerprint(),consent,System.currentTimeMillis()/1000)
  }
}
object WalletFirebase {
  val configured get() = listOf(BuildConfig.FIREBASE_APP_ID,BuildConfig.FIREBASE_PROJECT_ID,
    BuildConfig.FIREBASE_SENDER_ID,BuildConfig.FIREBASE_API_KEY).all { it.isNotBlank() }
  fun prepare(context: Context) {
    if (configured && FirebaseApp.getApps(context).isEmpty()) FirebaseApp.initializeApp(context,
      FirebaseOptions.Builder().setApplicationId(BuildConfig.FIREBASE_APP_ID).setProjectId(BuildConfig.FIREBASE_PROJECT_ID)
        .setGcmSenderId(BuildConfig.FIREBASE_SENDER_ID).setApiKey(BuildConfig.FIREBASE_API_KEY).build())
  }
}
