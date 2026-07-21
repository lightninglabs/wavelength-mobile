package engineering.lightning.wavewalletdk.client

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// WalletConfig is the typed mirror of the Go facade's JSON config. Only set
// fields are encoded (nulls are omitted), so the daemon's build-tag defaults
// fill in the rest. The @SerialName keys match the Go json tags (snake_case).

@Serializable
data class WalletConfig(
  @SerialName("data_dir") val dataDir: String,
  @SerialName("network") val network: String,

  @SerialName("server_address") val serverAddress: String? = null,
  @SerialName("server_transport") val serverTransport: String? = null,
  @SerialName("server_insecure") val serverInsecure: Boolean? = null,

  @SerialName("wallet_type") val walletType: String? = null,
  @SerialName("wallet_esplora_url") val walletEsploraUrl: String? = null,
  @SerialName("wallet_poll_interval_seconds")
  val walletPollIntervalSeconds: Long? = null,

  @SerialName("swap_server_address") val swapServerAddress: String? = null,
  @SerialName("swap_server_insecure") val swapServerInsecure: Boolean? = null,

  @SerialName("debug_level") val debugLevel: String? = null,
  @SerialName("allow_mainnet") val allowMainnet: Boolean? = null,
) {
  companion object {
    /**
     * Build a signet config for the lightweight (Esplora-backed) wallet. The
     * operator and swap endpoints default to Lightning Labs' public signet
     * deployment; pass empty strings to run sync-only without an operator.
     */
    fun signet(
      dataDir: String,
      esploraUrl: String = "https://mempool.space/signet/api",
      operatorAddress: String = "arkd-signet.testnet.lightningcluster.com:443",
      swapServerAddress: String = "swapd-signet.testnet.lightningcluster.com:443",
    ): WalletConfig = WalletConfig(
      dataDir = dataDir,
      network = "signet",
      walletType = "lwwallet",
      walletEsploraUrl = esploraUrl,
      walletPollIntervalSeconds = 30,
      // The operator and swap endpoints terminate TLS at :443, so they are
      // not insecure; leave the insecure flags unset (false).
      serverAddress = operatorAddress.ifEmpty { null },
      serverTransport = "grpc",
      swapServerAddress = swapServerAddress.ifEmpty { null },
      debugLevel = "info",
    )
  }
}
