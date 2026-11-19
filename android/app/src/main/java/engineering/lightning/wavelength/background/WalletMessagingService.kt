package engineering.lightning.wavelength.background

import android.content.Context
import engineering.lightning.wavelength.WalletApplication
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import engineering.lightning.wavelength.BuildConfig
import engineering.lightning.wavelength.data.WalletSession

/** Prepared data-only FCM ingress. No sender can supply a native RPC or amount. */
class WalletMessagingService : FirebaseMessagingService() {
  override fun onRegistered(installationId: String) {
    (application as WalletApplication).wallet.relay.schedule()
  }

  override fun onMessageReceived(message: RemoteMessage) {
    // Do not use FCM notification payloads: Android would display those before
    // local route/consent/proof checks while the process is in the background.
    if (message.notification != null) return
    val hint = PushHint.parse(message.data) ?: return
    // Both service admission and worker entry re-read local authority. No route
    // exists until a publisher's authenticated Android enrollment installs it.
    if (!RelayPushRegistry(this).contains(hint.routeId)) return
    val producer = if (hint.kind == "wake") {
      BackgroundProducerWake.parse(message.data["wake_reason"],message.data["wake_deadline_unix"])
    } else null
    WalletWork.opportunity(this,if (hint.kind == "wake") "Push wake" else "Payment hint",hint.routeId,producer = producer)
  }

}

/** Only a fully bound local route can admit a remote hint. */
class RelayPushRegistry(context: Context) {
  private val registration = (context.applicationContext as WalletApplication).wallet.relay
  private fun route(id: String) = registration.route(id)
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
