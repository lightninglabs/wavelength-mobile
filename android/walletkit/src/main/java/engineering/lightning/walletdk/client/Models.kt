package engineering.lightning.walletdk.client

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
