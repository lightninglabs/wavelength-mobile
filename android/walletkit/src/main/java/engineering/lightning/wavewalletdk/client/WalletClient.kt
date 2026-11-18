package engineering.lightning.wavewalletdk.client

import android.util.Base64
import engineering.lightning.wavewalletdk.mobile.Mobile
import kotlinx.coroutines.CancellationException
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

  /** Foreground ownership of network ingress; serialized by the host. */
  suspend fun setHostForeground(foreground: Boolean) = io { Mobile.setHostForeground(foreground) }

  /** Wallet balance summary. */
  suspend fun balance(): Balance = decode(io { Mobile.balance() })

  /** Confirmed balance in satoshis, without decoding a JSON payload. */
  suspend fun confirmedBalanceSat(): Long = io { Mobile.confirmedBalanceSat() }

  /** Generate recovery words without creating a wallet or storing a phrase copy. */
  suspend fun generateSeed(): GenerateSeedResult =
    decode(io { Mobile.generateSeed("{}".toByteArray()) })

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
   * Open a Lightning invoice to receive [amountSat] into the wallet. Share the
   * returned invoice with the payer; the matching entry shows up on the
   * activity stream as it is paid.
   */
  suspend fun receiveLightning(amountSat: Long, memo: String = "", requestId: String = java.util.UUID.randomUUID().toString()): ReceiveResult =
    decode(io { Mobile.receive(encode(ReceiveReq.serializer(), ReceiveReq(amountSat, memo, requestId))) })

  /** A successful absent lookup excludes a receive still being created under this ID. */
  suspend fun lookupReceive(requestId: String): ReceiveResult? {
    val result = decode<ReceiveLookupResult>(io {
      Mobile.lookupReceive(encode(ReceiveLookupReq.serializer(), ReceiveLookupReq(requestId)))
    })
    return if (result.found) requireNotNull(result.receive) { "Missing receive result" } else null
  }

  /**
   * Allocate a fresh on-chain boarding address to deposit into. The optional
   * hint lets the daemon size the boarding round; zero leaves it to the daemon.
   */
  suspend fun newDepositAddress(amountSatHint: Long = 0): DepositResult =
    decode(io { Mobile.deposit(encode(DepositReq.serializer(), DepositReq(amountSatHint))) })

  /**
   * Quote an outbound payment without moving funds. Set exactly one of [invoice]
   * or [onchainAddress]. The returned [PrepareSendResult] carries a single-use
   * intent id to pass to [send]. [sweepAll] drains every VTXO to the address.
   */
  suspend fun prepareSend(
    invoice: String? = null,
    onchainAddress: String? = null,
    amountSat: Long = 0,
    note: String = "",
    maxFeeSat: Long = 0,
    sweepAll: Boolean = false,
    maxCreditSat: Long = 10_000,
    maxCreditTopupSat: Long = 10_000,
    maxAmount: Boolean = false,
  ): PrepareSendResult = decode(
    io {
      Mobile.prepareSend(
        encode(
          PrepareSendReq.serializer(),
          PrepareSendReq(invoice, onchainAddress, amountSat, note, maxFeeSat, sweepAll, maxCreditSat, maxCreditTopupSat, maxAmount),
        ),
      )
    },
  )

  suspend fun decodeInvoice(invoice: String, network: String): InvoiceDetails = decode(io {
    Mobile.decodeInvoice(encode(InvoiceDecodeReq.serializer(), InvoiceDecodeReq(invoice, network)))
  })

  /** Dispatch a prepared send, consuming the single-use intent id. */
  suspend fun send(sendIntentId: String): SendResult =
    decode(io { Mobile.sendPrepared(encode(SendPreparedReq.serializer(), SendPreparedReq(sendIntentId))) })

  /**
   * Pay a Lightning invoice in one call, skipping the explicit quote step. Use
   * [prepareSend] + [send] instead when you want to show the fee before paying.
   */
  suspend fun payInvoice(invoice: String, maxFeeSat: Long = 0): SendResult {
    val quote = prepareSend(invoice = invoice, maxFeeSat = maxFeeSat)
    return send(quote.sendIntentId)
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
          send(json.decodeFromString(Entry.serializer(), String(next)))
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

  /**
   * List a unified wallet view: the merged activity history, the live VTXO
   * inventory, or the on-chain transaction history. Read the [ListResult] field
   * named by its `view`. Canonical activity uses [ActivityList.nextCursor]
   * and ignores offsets.
   */
  suspend fun list(
    view: ListView = ListView.ACTIVITY,
    kinds: List<String> = emptyList(),
    pendingOnly: Boolean = false,
    limit: Long = 0,
    offset: Long = 0,
    cursor: String = "",
  ): ListResult = decode(
    io {
      Mobile.list(
        encode(ListReq.serializer(), ListReq(view.wire, pendingOnly, kinds, limit, offset, cursor)),
      )
    },
  )

  /** Capture the end of the local transition log before reading a snapshot. */
  suspend fun activityCursor(): Long = decode<ActivityCursorResult>(io { Mobile.activityCursor() }).cursor

  /** Read current rows after [after]. Keep the returned high water until the range is drained. */
  suspend fun readActivityBatch(after: Long, through: Long = 0, limit: Int = 64): ActivityBatch =
    decode(io { Mobile.readActivityBatch(encode(ActivityBatchReq.serializer(), ActivityBatchReq(after, through, limit))) })

  /**
   * Exit a VTXO back to the chain. The daemon queues a cooperative leave by
   * default, paying out to [destination] (or a fresh backing-wallet address when
   * empty). To bypass cooperation and start a unilateral unroll, pass
   * [forceUnrollAck] = "I_KNOW_WHAT_I_AM_DOING"; it cannot be combined with
   * [destination]. Track progress with [exitStatus] or the activity stream.
   */
  suspend fun exit(
    outpoint: String,
    destination: String = "",
    forceUnrollAck: String = "",
  ): ExitResult = decode(
    io {
      Mobile.exit(encode(ExitReq.serializer(), ExitReq(outpoint, destination, forceUnrollAck)))
    },
  )

  /** Query the phase of an exit job for a VTXO outpoint. */
  suspend fun exitStatus(outpoint: String): ExitStatusResult =
    decode(io { Mobile.exitStatus(encode(ExitStatusReq.serializer(), ExitStatusReq(outpoint))) })

  /**
   * Stream only incoming payments (receives and deposits) as they arrive and
   * settle. A convenience over [activity] filtered to the credit kinds, useful
   * for a "you were paid" notification: watch for an [Entry] whose status
   * becomes "complete".
   */
  fun incomingPayments(includeExisting: Boolean = false): Flow<Entry> =
    activity(includeExisting = includeExisting, kinds = listOf("receive", "deposit"))

  /** Lossless protobuf JSON, including string-encoded 64-bit fields. */
  suspend fun diagnosticRead(view: DiagnosticView, outpoint: String = "", roundId: String = "",
    history: Boolean = false, pageToken: String = ""): kotlinx.serialization.json.JsonElement {
    val request = DiagnosticRequest(view.wire, outpoint, roundId, history, pageToken)
    return json.parseToJsonElement(String(io { Mobile.diagnosticRead(encode(DiagnosticRequest.serializer(), request)) }))
  }

  /** Bounded wallet-scoped native log snapshot with the SDK’s sensitive-entry filter. */
  suspend fun diagnosticLogs(): DiagnosticLogSnapshot = decode(io { Mobile.diagnosticLogs() })

  /** Advance persisted round/refresh work within the native maximum budget. */
  suspend fun runMaintenanceWindow(id: String, timeoutSeconds: Long = 30): MaintenanceResult =
    decode(io { Mobile.runMaintenanceWindow(id, timeoutSeconds) })

  /** Signal the exact window, retaining its caller until native cleanup returns. */
  suspend fun cancelMaintenanceWindow(id: String) = io { Mobile.cancelReceiptWindow(id) }

  /** Source/canonical proof for locally enrolled invoices only. */
  suspend fun readLightningReceipts(references: List<ReceiptReference>, since: Long): List<LightningReceipt> =
    decode(io { Mobile.readLightningReceipts(encode(ReceiptReadRequest.serializer(), ReceiptReadRequest(references, since))) })

  // --- internals -----------------------------------------------------------

  private suspend inline fun <T> io(crossinline block: () -> T): T =
    try {
      withContext(Dispatchers.IO) { block() }
    } catch (e: CancellationException) {
      throw e
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
    internal val DEFAULT_JSON = Json {
      encodeDefaults = true
      ignoreUnknownKeys = true
      explicitNulls = false
      coerceInputValues = true
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

@Serializable
private data class ReceiveReq(
  @SerialName("AmountSat") val amountSat: Long,
  @SerialName("Memo") val memo: String = "",
  @SerialName("RequestID") val requestId: String,
  @SerialName("TimeoutSeconds") val timeoutSeconds: Long = 20,
)

@Serializable
private data class ReceiveLookupReq(@SerialName("RequestID") val requestId: String)

@Serializable
private data class ReceiveLookupResult(
  @SerialName("Found") val found: Boolean,
  @SerialName("Receive") val receive: ReceiveResult? = null,
)

@Serializable
private data class DepositReq(
  @SerialName("AmountSatHint") val amountSatHint: Long = 0,
)

@Serializable
internal data class PrepareSendReq(
  @SerialName("Invoice") val invoice: String? = null,
  @SerialName("OnchainAddress") val onchainAddress: String? = null,
  @SerialName("AmountSat") val amountSat: Long = 0,
  @SerialName("Note") val note: String = "",
  @SerialName("MaxFeeSat") val maxFeeSat: Long = 0,
  @SerialName("SweepAll") val sweepAll: Boolean = false,
  @SerialName("MaxCreditSat") val maxCreditSat: Long = 10_000,
  @SerialName("MaxCreditTopupSat") val maxCreditTopupSat: Long = 10_000,
  @SerialName("MaxAmount") val maxAmount: Boolean = false,
)

@Serializable
private data class SendPreparedReq(
  @SerialName("SendIntentID") val sendIntentId: String,
)

@Serializable
private data class ListReq(
  @SerialName("View") val view: String,
  @SerialName("PendingOnly") val pendingOnly: Boolean = false,
  @SerialName("Kinds") val kinds: List<String> = emptyList(),
  @SerialName("Limit") val limit: Long = 0,
  @SerialName("Offset") val offset: Long = 0,
  @SerialName("Cursor") val cursor: String = "",
)

@Serializable
private data class ActivityCursorResult(val cursor: Long)

@Serializable
private data class ActivityBatchReq(
  @SerialName("after_cursor") val after: Long,
  @SerialName("through_cursor") val through: Long,
  val limit: Int,
)

@Serializable
private data class ExitReq(
  @SerialName("Outpoint") val outpoint: String,
  @SerialName("Destination") val destination: String = "",
  @SerialName("ForceUnrollAck") val forceUnrollAck: String = "",
)

@Serializable
private data class ExitStatusReq(
  @SerialName("Outpoint") val outpoint: String,
)

@Serializable private data class InvoiceDecodeReq(val invoice: String, val network: String)

@Serializable data class InvoiceDetails(
  @SerialName("amount_sat") val amountSat: Long? = null,
  val description: String = "",
  @SerialName("expires_at_unix") val expiresAtUnix: Long = 0,
)
