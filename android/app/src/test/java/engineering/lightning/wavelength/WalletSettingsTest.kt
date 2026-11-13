package engineering.lightning.wavelength

import engineering.lightning.wavelength.data.*
import org.junit.Assert.*
import org.junit.Test

class WalletSettingsTest {
  @Test fun publicNetworksUseSdkDefaultsAndSeparateDirectories() {
    val configs = WalletNetwork.entries.filter { it != WalletNetwork.REGTEST }.map {
      NetworkSettings().config(it, "/wallets/${it.wire}")
    }
    assertEquals(3, configs.map { it.dataDir }.toSet().size)
    assertTrue(configs.all { it.serverAddress == null && it.swapServerAddress == null && it.walletEsploraUrl == null })
    assertTrue(configs.all { it.hostDrivenIngress && it.durableRoundRuntime })
    assertEquals(listOf(false, false, true), configs.map { it.allowMainnet })
  }
  @Test fun invoiceHrpCannotCrossNetworks() {
    val requests = mapOf(WalletNetwork.SIGNET to "lntbs1230n1payload", WalletNetwork.TESTNET to "lntb1230n1payload",
      WalletNetwork.MAINNET to "lnbc1230n1payload", WalletNetwork.REGTEST to "lnbcrt1230n1payload")
    requests.forEach { (selected, invoice) ->
      WalletNetwork.entries.forEach { network -> assertEquals(network == selected, network.acceptsInvoice(invoice)) }
      assertTrue(selected.acceptsInvoice(invoice.uppercase()))
    }
  }
  @Test fun customConnectionsAreTrimmedButNeverReplaceAnotherNetworkDefault() {
    val endpoints = EndpointOverrides(" operator.example:443 ", "swap.example:443", " https://example.com/api/ ").validated()
    assertEquals("https://example.com/api", endpoints.esplora)
    val custom = NetworkSettings(endpoints).config(WalletNetwork.TESTNET, "/wallets/testnet")
    val signet = NetworkSettings().config(WalletNetwork.SIGNET, "/wallets/signet")
    assertEquals("operator.example:443", custom.serverAddress)
    assertNull(signet.serverAddress)
  }
  @Test fun regtestRequiresExplicitServices() {
    assertThrows(IllegalArgumentException::class.java) { NetworkSettings().config(WalletNetwork.REGTEST, "/wallets/regtest") }
    val value = NetworkSettings(EndpointOverrides("10.0.2.2:50051", "10.0.2.2:50052", "http://10.0.2.2:3000"))
      .config(WalletNetwork.REGTEST, "/wallets/regtest")
    assertEquals(true, value.serverInsecure)
    assertEquals(false, value.allowMainnet)
  }
  @Test fun creditLimitsRetainAnExplicitZeroAndRejectNegativeAmounts() {
    assertEquals(0L, CreditLimits(0, 0).use)
    assertThrows(IllegalArgumentException::class.java) { CreditLimits(-1, 10000) }
    assertThrows(IllegalArgumentException::class.java) { EndpointOverrides(esplora = "file:///tmp/secret").validated() }
  }
}
