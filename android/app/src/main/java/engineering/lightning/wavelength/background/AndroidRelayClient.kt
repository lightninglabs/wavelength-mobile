package engineering.lightning.wavelength.background

import android.content.Context
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import com.google.android.gms.tasks.Tasks
import engineering.lightning.wavelength.BuildConfig
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.IOException
import java.net.URI
import java.nio.ByteBuffer
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import javax.net.ssl.HttpsURLConnection
import org.json.JSONObject

/** Direct-APK installation credential. Pair the displayed public fingerprint
 * after verifying the APK signer on a trusted installation. */
internal class AndroidRelayClient(private val context: Context, origin: String, private val alias: String) {
  private val base = URI(origin).also {
    require(it.scheme == "https" && it.host != null && it.userInfo == null &&
      it.rawQuery == null && it.rawFragment == null && it.path in listOf("", "/"))
    require(alias.matches(Regex("[A-Za-z0-9_.-]{1,100}")))
  }
  private val credential = "wavelength.push." + digest((origin + "\u0000" + alias).toByteArray()).hex()
  private val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
  private val publicKey: ByteArray by lazy {
      if (!store.containsAlias(credential)) {
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
          initialize(KeyGenParameterSpec.Builder(credential, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256).build())
        }.generateKeyPair()
      }
      store.getCertificate(credential).publicKey.encoded
    }

  val fingerprint get() = b64(digest(publicKey))
  private val installation get() = digest((alias + "\u0000").toByteArray() + digest(publicKey)).hex()

  private fun sign(bytes: ByteArray): ByteArray = Signature.getInstance("SHA256withECDSA").run {
    initSign(store.getKey(credential, null) as PrivateKey)
    update(bytes)
    sign()
  }

  private fun post(path: String, body: JSONObject): JSONObject {
    val conn = base.resolve(path).toURL().openConnection() as HttpsURLConnection
    try {
      conn.instanceFollowRedirects = false
      conn.connectTimeout = 8000
      conn.readTimeout = 12000
      conn.requestMethod = "POST"
      conn.doOutput = true
      conn.setRequestProperty("Content-Type", "application/json")
      conn.outputStream.use { it.write(body.toString().toByteArray()) }
      if (conn.responseCode !in 200..299) throw RelayHttpError(conn.responseCode)
      val data = conn.inputStream.buffered().use { input ->
        val output = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(4096)
        while (true) {
          val n = input.read(chunk)
          if (n < 0) break
          require(output.size() + n <= 65536)
          output.write(chunk, 0, n)
        }
        output.toByteArray()
      }
      return JSONObject(String(data, Charsets.UTF_8))
    } finally { conn.disconnect() }
  }

  /** A lost enrollment response is recoverable by signing management for the
   * deterministic installation ID. No retry changes the installation key. */
  fun enroll(destination: String) {
    val result = request("enroll", JSONObject().put("device_token", destination), null)
    require(result.getString("installation_id") == installation)
  }

  fun manage(action: JSONObject, counter: Long) = request("manage", action, counter)

  private fun request(operation: String, payload: JSONObject, counter: Long?): JSONObject {
    val id = if (counter == null) "" else installation
    val ask = JSONObject().put("app_id", alias).put("operation", operation)
    if (counter != null) ask.put("installation_id", id)
    val challenge = post("/v1/challenges", ask)
    require(challenge.getString("app_id") == alias && challenge.getString("operation") == operation &&
      challenge.optString("installation_id") == id && challenge.getLong("expires_at") > System.currentTimeMillis()/1000)
    val body = payload.toString().toByteArray()
    val transcript = listOf("wavelength.notification-relay.v1", operation, alias, id,
      challenge.getString("id"), challenge.getString("nonce"), digest(body).hex(), "").joinToString("\n").toByteArray()
    val envelope = JSONObject().put("challenge_id", challenge.getString("id")).put("payload", b64(body))
    val proof = if (counter == null) {
      envelope.put("key_id", fingerprint)
      val evidence = JSONObject().put("key", b64(publicKey)).put("signature", b64(sign(transcript)))
      if (!(BuildConfig.DEBUG && alias.endsWith(".emulator"))) {
        val nonce = Base64.encodeToString(digest((fingerprint + "\n").toByteArray() + transcript),
          Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        val request = IntegrityTokenRequest.builder().setCloudProjectNumber(BuildConfig.FIREBASE_SENDER_ID.toLong())
          .setNonce(nonce).build()
        val token = Tasks.await(IntegrityManagerFactory.create(context).requestIntegrityToken(request),
          30, java.util.concurrent.TimeUnit.SECONDS)
        evidence.put("integrity", token.token())
      }
      evidence.toString().toByteArray()
    } else {
      require(counter in 1..0xffffffffL)
      val prefix = ByteBuffer.allocate(4).putInt(counter.toInt()).array()
      prefix + sign(prefix + transcript)
    }
    envelope.put("proof", b64(proof))
    return post(if (counter == null) "/v1/installations" else "/v1/installations/$id/manage", envelope)
  }
}

internal class RelayHttpError(val status: Int) : IOException("Relay HTTP $status")
internal fun digest(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
internal fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
private fun b64(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
