package engineering.lightning.wavelength.background

import android.content.Context
import android.util.AtomicFile
import androidx.work.*
import com.google.android.gms.tasks.Tasks
import com.google.firebase.installations.FirebaseInstallations
import com.google.firebase.messaging.FirebaseMessaging
import engineering.lightning.wavewalletdk.client.NotificationFeedGrant
import engineering.lightning.wavelength.BuildConfig
import engineering.lightning.wavelength.WalletApplication
import engineering.lightning.wavelength.data.WalletSession
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

@Serializable internal data class PushTarget(val route: String, val network: String, val identity: String, val connection: String)
@Serializable internal data class RemoteGrant(val target: PushTarget, val subscription: String, val expires: Long)
@Serializable internal data class RegistrationState(val desired: PushTarget? = null,
  val grant: RemoteGrant? = null, val bound: RelayRoute? = null, val counter: Long = 0,
  val destination: String = "", val confirmed: Boolean = false,
  val retired: List<RemoteGrant> = emptyList()) {
  fun select(target: PushTarget?) = copy(desired = target, bound = null)

  fun retire(grant: RemoteGrant) = copy(grant = null, bound = null, retired = retired + grant)

  fun publish(target: PushTarget, expiry: Long): RegistrationState {
    if (desired != target || grant?.target != target) return this
    return copy(bound = RelayRoute(target.route, target.network, target.identity, target.connection, expiry))
  }
}

/** One process owns consent, the pending grant and the published route. Each
 * mutation preserves fields written while a remote call was in flight. */
internal class RelayRegistration(private val context: Context) {
  private val serial = Mutex()
  private val config = listOf(BuildConfig.FIREBASE_PROJECT_ID, BuildConfig.FIREBASE_RELAY_URL,
    BuildConfig.FIREBASE_RELAY_ALIAS, BuildConfig.FIREBASE_RELAY_NETWORK).joinToString("\u0000")
  private val file = AtomicFile(File(context.noBackupFilesDir, "relay-" + digest(config.toByteArray()).hex() + ".json"))
  private val client by lazy { AndroidRelayClient(context, BuildConfig.FIREBASE_RELAY_URL, BuildConfig.FIREBASE_RELAY_ALIAS) }
  val configured get() = WalletFirebase.configured && BuildConfig.FIREBASE_RELAY_URL.isNotBlank() &&
    BuildConfig.FIREBASE_RELAY_ALIAS.isNotBlank() && BuildConfig.FIREBASE_RELAY_NETWORK.isNotBlank() && BuildConfig.FIREBASE_RELAY_SWAP_ISSUER.matches(Regex("0[23][a-f0-9]{64}"))
  val pairingID get() = client.fingerprint
  private fun now() = System.currentTimeMillis() / 1000

  @Synchronized private fun read(): RegistrationState {
    if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return RegistrationState()
    return Json.decodeFromString(file.readFully().toString(Charsets.UTF_8))
  }
  @Synchronized private fun update(f: (RegistrationState) -> RegistrationState): RegistrationState {
    val state = f(read())
    val out = file.startWrite()
    try {
      out.write(Json.encodeToString(RegistrationState.serializer(), state).toByteArray())
      file.finishWrite(out)
    } catch (error: Throwable) { file.failWrite(out); throw error }
    return state
  }

  fun stillDesired(target: PushTarget) = read().desired == target
  fun wants(network: String, identity: String, connection: String): Boolean = read().desired?.let {
    it.network == network && it.identity == identity && it.connection == connection
  } == true
  fun select(network: String, identity: String, connection: String, enabled: Boolean) {
    require(configured && network == BuildConfig.FIREBASE_RELAY_NETWORK && identity.isNotBlank())
    val target = if (enabled) PushTarget(UUID.randomUUID().toString(),network,identity,connection) else null
    update { it.select(target) }
    schedule(afterCurrent = true)
  }
  fun route(id: String): RelayRoute? = runCatching { read().let { state ->
    state.bound?.takeIf { it.id == id && state.desired?.route == id && it.expiresAt > now() }
  } }.getOrNull()

  fun schedule(afterCurrent: Boolean = false) {
    if (!configured) return
    val request = OneTimeWorkRequestBuilder<RelayRegistrationWorker>()
      .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build()
    WorkManager.getInstance(context).enqueueUniqueWork("wallet-relay-registration",
      if (afterCurrent) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP, request)
  }
  private fun manage(body: JSONObject): JSONObject {
    val counter = update { it.copy(counter = it.counter + 1) }.counter
    return client.manage(body,counter)
  }

  suspend fun reconcile(wallet: WalletSession) = serial.withLock { reconcileLocked(wallet) }

  private suspend fun reconcileLocked(wallet: WalletSession) = withContext(Dispatchers.IO) {
    val current = read()
    val desired = current.desired
    val old = current.grant
    if (old != null && old.target != desired) {
      if (old.expires > now()) {
        manage(JSONObject().put("action","revoke_subscription").put("subscription_id",old.subscription))
      }
      update { it.retire(old) }
    }
    // The relay already revoked these routes. Each wallet removes its producer
    // grants when it next opens, or the producers expire them automatically.
    for (retired in read().retired) {
      if (retired.expires > now()) {
        try {
          for (role in listOf("operator", "swap_server")) {
            wallet.signRelayGrant(retired.target, NotificationFeedGrant(role, retired.subscription, remove = true))
          }
        } catch (e: CancellationException) {
          throw e
        } catch (_: Exception) {
          // Keep the retired grant for a later cleanup without blocking enrollment.
          continue
        }
      }
      update { it.copy(retired = it.retired - retired) }
    }
    if (desired == null) return@withContext
    val fcm = FirebaseMessaging.getInstance()
    Tasks.await(fcm.register(), 30, TimeUnit.SECONDS)
    val fid = Tasks.await(FirebaseInstallations.getInstance().id, 15, TimeUnit.SECONDS)
    val tokenHash = digest(fid.toByteArray()).hex()
    if (!current.confirmed || current.destination != tokenHash || current.bound == null ||
      current.bound.expiresAt <= now() + 86400) {
      try {
        manage(JSONObject().put("action","rotate_token").put("device_token",fid))
      } catch (error: RelayHttpError) {
        if (error.status != 401 || current.confirmed) throw error
        client.enroll(fid)
      }
      update { it.copy(confirmed = true, destination = tokenHash) }
    }
    if (current.bound?.let { it.id == desired.route && it.expiresAt > now() + 86400 } == true) return@withContext
    if (read().desired != desired) return@withContext
    val result = manage(JSONObject().put("action","subscribe").put("route_id",desired.route)
      .put("enable_alerts",true).put("alert_presentation","receipt_hint"))
    val id = result.getString("subscription_id")
    val expiry = result.getLong("expires_at")
    require(id.matches(Regex("[A-Za-z0-9_-]{22,64}")) && expiry > now() &&
      result.getString("alert_presentation") == "receipt_hint")
    update { it.copy(grant = RemoteGrant(desired,id,expiry)) }
    val array = result.getJSONArray("feed_offers")
    require(array.length() in 1..16)
    val offers = (0 until array.length()).map { array.getJSONObject(it) }
    // Choose native producer roles from the wallet's own network configuration.
    val roles = listOf("operator","swap_server")
    var boundExpiry = expiry
    for (role in roles) {
      val offer = offers.single { it.getString("role") == role }
      if (role == "swap_server") require(offer.getString("source_pubkey") == BuildConfig.FIREBASE_RELAY_SWAP_ISSUER)
      val classes = offer.getInt("event_classes")
      val until = offer.getLong("expires_at_unix")
      require(offer.getString("grant_id") == id && classes in 1..7 && until > now() && until <= expiry)
      val signed = wallet.signRelayGrant(desired, NotificationFeedGrant(
        source = role,
        grantId = id,
        subscriberPubkey = offer.getString("subscriber_pubkey"),
        subscriberSignature = offer.getString("subscriber_signature"),
        eventClasses = classes,
        expiresAt = until,
      ))
      val expires = signed.expiresAt
      require(signed.grantId == id && expires > now() && expires <= until)
      manage(JSONObject().put("action","bind_feed").put("subscription_id",id)
        .put("feed_binding",JSONObject().put("source_id",offer.getString("source_id"))
          .put("feed_token",signed.feedToken).put("event_classes",classes)
          .put("expires_at_unix",expires)))
      boundExpiry = minOf(boundExpiry, expires)
    }
    update { it.publish(desired, boundExpiry) }
  }
}

internal class RelayWalletUnavailable : Exception()

class RelayRegistrationWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
  override suspend fun doWork(): Result {
    val wallet = (applicationContext as WalletApplication).wallet
    return try { wallet.relay.reconcile(wallet); Result.success() }
    catch (_: RelayWalletUnavailable) { Result.success() }
    catch (e: CancellationException) { throw e }
    catch (_: Exception) { Result.retry() }
  }
}
