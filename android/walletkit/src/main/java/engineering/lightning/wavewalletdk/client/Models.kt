package engineering.lightning.wavewalletdk.client

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// The wrapper decodes the JSON the Go facade emits. The Go DTOs carry no json
// tags, so their wire keys are the Go field names (PascalCase); each model maps
// them with @SerialName and exposes idiomatic camelCase Kotlin properties.
// Json is configured with ignoreUnknownKeys, so a model may cover a subset of
// the fields a verb returns.

/** Wallet lifecycle state reported by the daemon. */
enum class WalletState(val code: Int) {
  UNSPECIFIED(0),
  NONE(1),
  LOCKED(2),
  READY(3),
  SYNCING(4);

  companion object {
    fun fromCode(code: Int): WalletState =
      entries.firstOrNull { it.code == code } ?: UNSPECIFIED
  }
}

/** Daemon readiness snapshot (`getInfo`). */
@Serializable
data class Info(
  @SerialName("Version") val version: String = "",
  @SerialName("Commit") val commit: String = "",
  @SerialName("Network") val network: String = "",
  @SerialName("BlockHeight") val blockHeight: Long = 0,
  @SerialName("ServerConnected") val serverConnected: Boolean = false,
  @SerialName("WalletType") val walletType: String = "",
  @SerialName("WalletState") val walletStateCode: Int = 0,
  @SerialName("IdentityPubKey") val identityPubKey: String = "",
) {
  val walletState: WalletState get() = WalletState.fromCode(walletStateCode)
  val walletReady: Boolean get() = walletState == WalletState.READY
}

/** Wallet balance summary (`balance`). */
@Serializable
data class Balance(
  @SerialName("ConfirmedSat") val confirmedSat: Long = 0,
  @SerialName("PendingInSat") val pendingInSat: Long = 0,
  @SerialName("PendingOutSat") val pendingOutSat: Long = 0,
)

/** Wallet readiness + pending activity (`status`). */
@Serializable
data class Status(
  @SerialName("Ready") val ready: Boolean = false,
  @SerialName("Unlocked") val unlocked: Boolean = false,
  @SerialName("Network") val network: String = "",
  @SerialName("Balance") val balance: Balance = Balance(),
  @SerialName("PendingCount") val pendingCount: Long = 0,
)

/** Result of creating or importing a wallet (`createWallet`). */
@Serializable
data class CreateWalletResult(
  @SerialName("Mnemonic") val mnemonic: List<String> = emptyList(),
  @SerialName("EncipheredSeed") val encipheredSeed: String? = null,
  @SerialName("IdentityPubKey") val identityPubKey: String = "",
  @SerialName("RecoveryRan") val recoveryRan: Boolean = false,
)

/** Result of unlocking a wallet (`unlockWallet`). */
@Serializable
data class UnlockWalletResult(
  @SerialName("IdentityPubKey") val identityPubKey: String = "",
)

/** One activity entry from the wallet stream (`subscribe`) or list view. */
@Serializable
data class Entry(
  @SerialName("ID") val id: String = "",
  @SerialName("Kind") val kind: String = "",
  @SerialName("Status") val status: String = "",
  @SerialName("AmountSat") val amountSat: Long = 0,
  @SerialName("FeeSat") val feeSat: Long = 0,
  @SerialName("Counterparty") val counterparty: String = "",
  @SerialName("CreatedAt") val createdAt: String = "",
  @SerialName("UpdatedAt") val updatedAt: String = "",
  @SerialName("Note") val note: String = "",
  @SerialName("FailureReason") val failureReason: String = "",
)

/** A Lightning invoice to receive into the wallet, plus its initial entry. */
@Serializable
data class ReceiveResult(
  @SerialName("Invoice") val invoice: String = "",
  @SerialName("Entry") val entry: Entry = Entry(),
)

/** A fresh on-chain boarding address to deposit into, plus its initial entry. */
@Serializable
data class DepositResult(
  @SerialName("Address") val address: String = "",
  @SerialName("Entry") val entry: Entry = Entry(),
)

/**
 * A quote for an outbound payment. Show the fee, then dispatch the quote with
 * [WalletClient.send] using the single-use [sendIntentId]. The fee is only known
 * up front when [feeKnown] is true.
 */
@Serializable
data class PrepareSendResult(
  @SerialName("SendIntentID") val sendIntentId: String = "",
  @SerialName("AmountSat") val amountSat: Long = 0,
  @SerialName("ExpectedFeeSat") val expectedFeeSat: Long = 0,
  @SerialName("FeeKnown") val feeKnown: Boolean = false,
  @SerialName("ExpectedTotalOutflowSat") val expectedTotalOutflowSat: Long = 0,
  @SerialName("Rail") val rail: String = "",
  @SerialName("QuoteStatus") val quoteStatus: String = "",
  @SerialName("DestinationSummary") val destinationSummary: String = "",
  @SerialName("PaymentHash") val paymentHash: String = "",
  @SerialName("Warning") val warning: String = "",
)

/**
 * The result of dispatching a prepared send. [actualAmountSat] is what actually
 * left the wallet, which matters for a sweep-all send where the amount is the
 * swept total rather than a requested figure.
 */
@Serializable
data class SendResult(
  @SerialName("Entry") val entry: Entry = Entry(),
  @SerialName("ActualAmountSat") val actualAmountSat: Long = 0,
)

/** Which slice of wallet state [WalletClient.list] returns. */
enum class ListView(val wire: String) {
  ACTIVITY("activity"),
  VTXOS("vtxos"),
  ONCHAIN("onchain"),
}

/**
 * A unified wallet view. It is a tagged union: read the field named by [view]
 * and treat the others as null.
 */
@Serializable
data class ListResult(
  @SerialName("View") val view: String = "activity",
  @SerialName("Activity") val activity: ActivityList? = null,
  @SerialName("VTXOs") val vtxos: VTXOInventory? = null,
  @SerialName("Onchain") val onchain: OnchainHistory? = null,
)

/** The merged activity stream (sends, receives, deposits, exits). */
@Serializable
data class ActivityList(
  @SerialName("Entries") val entries: List<Entry> = emptyList(),
  @SerialName("Total") val total: Long = 0,
)

/** The live VTXO inventory. */
@Serializable
data class VTXOInventory(
  @SerialName("VTXOs") val vtxos: List<WalletVTXO> = emptyList(),
  @SerialName("Total") val total: Long = 0,
)

/** The wallet-facing view of one VTXO. */
@Serializable
data class WalletVTXO(
  @SerialName("Outpoint") val outpoint: String = "",
  @SerialName("AmountSat") val amountSat: Long = 0,
  @SerialName("Status") val status: String = "",
  @SerialName("BatchExpiry") val batchExpiry: Int = 0,
  @SerialName("RelativeExpiry") val relativeExpiry: Long = 0,
  @SerialName("CommitmentTxid") val commitmentTxid: String = "",
)

/** The on-chain transaction history (boarding, sweeps, leave outputs). */
@Serializable
data class OnchainHistory(
  @SerialName("Txs") val txs: List<OnchainTx> = emptyList(),
  @SerialName("Total") val total: Long = 0,
  @SerialName("HasMore") val hasMore: Boolean = false,
)

/** The wallet-facing view of one on-chain transaction. */
@Serializable
data class OnchainTx(
  @SerialName("Txid") val txid: String = "",
  @SerialName("Kind") val kind: String = "",
  @SerialName("AmountSat") val amountSat: Long = 0,
  @SerialName("FeeSat") val feeSat: Long = 0,
  @SerialName("Status") val status: String = "",
  @SerialName("ConfirmationHeight") val confirmationHeight: Int = 0,
  @SerialName("CreatedAt") val createdAt: String = "",
  @SerialName("Description") val description: String = "",
)

/**
 * The outcome of an exit. [path] is "cooperative" (the operator admitted a
 * cooperative leave; [queuedOutpoints] echoes the selection) or "unilateral"
 * (a forced unroll job started; [actorId] owns it).
 */
@Serializable
data class ExitResult(
  @SerialName("Path") val path: String = "",
  @SerialName("Cooperative") val cooperative: Boolean = false,
  @SerialName("QueuedOutpoints") val queuedOutpoints: List<String> = emptyList(),
  @SerialName("Created") val created: Boolean = false,
  @SerialName("ActorID") val actorId: String = "",
)

/**
 * The phase of an exit job. [found] is false when no job exists for the
 * outpoint (not an error). [status] is pending / materializing / csv_pending /
 * sweeping / completed / failed.
 */
@Serializable
data class ExitStatusResult(
  @SerialName("Found") val found: Boolean = false,
  @SerialName("Status") val status: String = "",
  @SerialName("SweepTxid") val sweepTxid: String = "",
  @SerialName("LastError") val lastError: String = "",
)
