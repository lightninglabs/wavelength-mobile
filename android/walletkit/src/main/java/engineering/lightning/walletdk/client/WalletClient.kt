package engineering.lightning.walletdk.client

import android.util.Base64
import engineering.lightning.walletdk.mobile.Mobile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Thrown when an embedded-wallet call fails. Wraps the Go-side error message. */
class WalletException(message: String?) : Exception(message)

/**
 * An idiomatic Kotlin facade over the gomobile `Mobile` bindings.
 *
 * Every call is a `suspend` function that runs the blocking binding on
 * [Dispatchers.IO] and returns a typed model (or throws [WalletException]).
 * The wallet activity stream is exposed as a [Flow] that closes its underlying
 * subscription when collection stops. One embedded daemon runs per process, so
 * a single `WalletClient` is enough for the whole app.
 */
class WalletClient(private val json: Json = DEFAULT_JSON) {

  /** Whether the embedded daemon is currently running. */
  val isRunning: Boolean get() = Mobile.isRunning()

  /** Boot the embedded daemon and block until its gRPC channel is serving. */
  suspend fun start(config: WalletConfig) = io {
    Mobile.start(json.encodeToString(WalletConfig.serializer(), config))
  }

  /** Tear the daemon down. Idempotent. */
  suspend fun stop() = io { Mobile.stop() }

  /** Daemon readiness snapshot. */
  suspend fun getInfo(): Info = decode(io { Mobile.getInfo() })

  /** Wallet readiness, balance, and pending-activity count. */
  suspend fun status(): Status = decode(io { Mobile.status() })

  /** Wallet balance summary. */
  suspend fun balance(): Balance = decode(io { Mobile.balance() })

  /** Confirmed balance in satoshis, without decoding a JSON payload. */
  suspend fun confirmedBalanceSat(): Long = io { Mobile.confirmedBalanceSat() }

  /** Create or import the wallet. An empty mnemonic generates a fresh seed. */
  suspend fun createWallet(
    walletPassword: ByteArray,
    mnemonic: List<String> = emptyList(),
  ): CreateWalletResult {
    val req = CreateWalletReq(
      mnemonic = mnemonic,
      walletPassword = base64(walletPassword),
    )
    return decode(
      io { Mobile.createWallet(encode(CreateWalletReq.serializer(), req)) },
    )
  }

  /** Unlock an existing wallet. */
  suspend fun unlockWallet(walletPassword: ByteArray): UnlockWalletResult {
    val req = UnlockWalletReq(base64(walletPassword))
    return decode(
      io { Mobile.unlockWallet(encode(UnlockWalletReq.serializer(), req)) },
    )
  }

  /**
   * Stream wallet activity as a [Flow]. Each emission is one [Entry]; the flow
   * completes on a clean end-of-stream and fails with [WalletException] on a
   * real error. Cancelling collection closes the underlying subscription,
   * which unblocks the pull loop.
   */
  fun activity(
    includeExisting: Boolean = false,
    kinds: List<String> = emptyList(),
  ): Flow<Entry> = channelFlow {
    val req = encode(SubscribeReq.serializer(), SubscribeReq(includeExisting, kinds))
    val sub = Mobile.subscribe(req)

    val pump = launch(Dispatchers.IO) {
      try {
        while (isActive) {
          val next = try {
            sub.next()
          } catch (e: Exception) {
            if (isEndOfStream(e)) break else throw WalletException(e.message)
          }
          trySend(json.decodeFromString(Entry.serializer(), String(next)))
        }
        close()
      } catch (e: Throwable) {
        close(e)
      }
    }

    awaitClose {
      sub.close()
      pump.cancel()
    }
  }

  // --- internals -----------------------------------------------------------

  private suspend inline fun <T> io(crossinline block: () -> T): T =
    try {
      withContext(Dispatchers.IO) { block() }
    } catch (e: WalletException) {
      throw e
    } catch (e: Exception) {
      throw WalletException(e.message)
    }

  private inline fun <reified T> decode(bytes: ByteArray): T =
    json.decodeFromString(String(bytes))

  private fun <T> encode(
    serializer: kotlinx.serialization.SerializationStrategy<T>,
    value: T,
  ): ByteArray = json.encodeToString(serializer, value).toByteArray()

  companion object {
    private val DEFAULT_JSON = Json {
      ignoreUnknownKeys = true
      explicitNulls = false
    }

    private fun base64(b: ByteArray): String = Base64.encodeToString(b, Base64.NO_WRAP)

    private fun isEndOfStream(e: Exception): Boolean =
      e.message?.contains("EOF", ignoreCase = true) == true
  }
}

@Serializable
private data class CreateWalletReq(
  @SerialName("Mnemonic") val mnemonic: List<String> = emptyList(),
  @SerialName("WalletPassword") val walletPassword: String,
)

@Serializable
private data class UnlockWalletReq(
  @SerialName("WalletPassword") val walletPassword: String,
)

@Serializable
private data class SubscribeReq(
  @SerialName("IncludeExisting") val includeExisting: Boolean = false,
  @SerialName("Kinds") val kinds: List<String> = emptyList(),
)
