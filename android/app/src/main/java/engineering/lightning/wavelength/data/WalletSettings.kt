package engineering.lightning.wavelength.data

import android.app.KeyguardManager
import android.content.Context
import engineering.lightning.wavewalletdk.client.WalletConfig
import java.net.URI

/** Wallet directories, credentials and operation journals share this namespace. */
enum class WalletNetwork(val wire: String, val title: String, val invoiceHrp: String,
  val operator: String, val swap: String, val esplora: String) {
  SIGNET("signet", "Signet", "lntbs", "signet.wavelength.lightning.finance:443",
    "swap.signet.wavelength.lightning.finance:443", "https://mempool-signet.testnet.lightningcluster.com/api"),
  TESTNET("testnet", "Testnet", "lntb", "test.wavelength.lightning.finance:443",
    "swap.test.wavelength.lightning.finance:443", "https://mempool-testnet3.testnet.lightningcluster.com/api"),
  MAINNET("mainnet", "Mainnet", "lnbc", "wavelength.lightning.finance:443",
    "swap.wavelength.lightning.finance:443", "https://mempool.staging.lightningcluster.com/api"),
  REGTEST("regtest", "Regtest", "lnbcrt", "", "", "");

  fun acceptsInvoice(value: String): Boolean = Regex("^${invoiceHrp}(?:[0-9]+[munp]?)?1", RegexOption.IGNORE_CASE).containsMatchIn(value)
  companion object { fun fromWire(value: String?) = entries.firstOrNull { it.wire == value } ?: SIGNET }
}

enum class WalletAppearance(val title: String) { SYSTEM("System"), DARK("Signal Dark"), LIGHT("Porcelain Light") }

data class EndpointOverrides(val operator: String = "", val swap: String = "", val esplora: String = "") {
  fun validated(): EndpointOverrides {
    val value = copy(operator = operator.trim(), swap = swap.trim(), esplora = esplora.trim().trimEnd('/'))
    require(listOf(value.operator, value.swap, value.esplora).none { it.any(Char::isWhitespace) }) { "Endpoints cannot contain spaces." }
    if (value.esplora.isNotEmpty()) {
      val uri = URI(value.esplora)
      require(uri.scheme in listOf("https", "http") && !uri.host.isNullOrBlank() && uri.userInfo == null) { "Enter an HTTP or HTTPS Esplora URL." }
    }
    return value
  }
}

data class CreditLimits(val use: Long = 10_000, val topup: Long = 10_000) {
  init { require(use >= 0 && topup >= 0) { "Credit limits cannot be negative." } }
}

data class NetworkSettings(val endpoints: EndpointOverrides = EndpointOverrides(), val credit: CreditLimits = CreditLimits()) {
  fun config(network: WalletNetwork, directory: String): WalletConfig {
    require(network != WalletNetwork.REGTEST || listOf(endpoints.operator, endpoints.swap, endpoints.esplora).all { it.isNotBlank() }) {
      "Set the Regtest connection before starting its wallet."
    }
    return WalletConfig(dataDir = directory, network = network.wire,
      walletType = "lwwallet", serverTransport = "grpc", hostDrivenIngress = true,
      serverAddress = endpoints.operator.ifBlank { null }, swapServerAddress = endpoints.swap.ifBlank { null },
      walletEsploraUrl = endpoints.esplora.ifBlank { null },
      serverInsecure = network == WalletNetwork.REGTEST, swapServerInsecure = network == WalletNetwork.REGTEST,
      allowMainnet = network == WalletNetwork.MAINNET, diagnosticLogs = true,
      walletPollIntervalSeconds = when (network) { WalletNetwork.MAINNET -> 30; WalletNetwork.REGTEST -> 1; else -> 10 }, debugLevel = "info")
  }
}

/** Global interaction preferences, with connection and credit limits per wallet. */
class WalletPreferences(context: Context) {
  private val preferences = context.getSharedPreferences("wallet-settings", Context.MODE_PRIVATE)
  private val secureDevice = context.getSystemService(KeyguardManager::class.java).isDeviceSecure
  val selectedNetwork get() = WalletNetwork.fromWire(preferences.getString("network", null))
  val appearance get() = runCatching { WalletAppearance.valueOf(preferences.getString("appearance", "SYSTEM")!!) }.getOrDefault(WalletAppearance.SYSTEM)
  val authentication get() = preferences.getBoolean("authentication", secureDevice)
  fun network(network: WalletNetwork): NetworkSettings {
    fun text(key: String) = preferences.getString("${network.wire}.$key", "").orEmpty()
    return NetworkSettings(EndpointOverrides(text("operator"), text("swap"), text("esplora")),
      CreditLimits(preferences.getLong("${network.wire}.credit", 10_000), preferences.getLong("${network.wire}.topup", 10_000)))
  }
  fun select(network: WalletNetwork) { check(preferences.edit().putString("network", network.wire).commit()) { "Could not save the selected network." } }
  fun appearance(value: WalletAppearance) { check(preferences.edit().putString("appearance", value.name).commit()) { "Could not save appearance." } }
  fun authentication(value: Boolean) { check(preferences.edit().putBoolean("authentication", value).commit()) { "Could not save security preference." } }
  fun endpoints(network: WalletNetwork, value: EndpointOverrides) {
    val valid = value.validated()
    check(preferences.edit().putString("${network.wire}.operator", valid.operator).putString("${network.wire}.swap", valid.swap)
      .putString("${network.wire}.esplora", valid.esplora).commit()) { "Could not save the connection." }
  }
  fun credit(network: WalletNetwork, value: CreditLimits) {
    check(preferences.edit().putLong("${network.wire}.credit", value.use).putLong("${network.wire}.topup", value.topup).commit()) { "Could not save credit limits." }
  }
}
