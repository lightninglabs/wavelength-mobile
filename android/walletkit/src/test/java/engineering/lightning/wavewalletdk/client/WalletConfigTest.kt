package engineering.lightning.wavewalletdk.client

import kotlinx.serialization.json.Json
import org.junit.Assert.assertTrue
import org.junit.Test

class WalletConfigTest {
  private val json = WalletClient.DEFAULT_JSON

  @Test
  fun signetEncodesOperatorAndEsplora() {
    val s = json.encodeToString(
      WalletConfig.serializer(),
      WalletConfig.signet(dataDir = "/tmp/wallet"),
    )
    assertTrue("missing server_address: $s", s.contains("\"server_address\""))
    assertTrue("missing operator host: $s", s.contains("signet.wavelength"))
    assertTrue("missing esplora: $s", s.contains("mempool-signet"))
    assertTrue("missing network: $s", s.contains("\"network\":\"signet\""))
    assertTrue("durable runtime must be explicit: $s", s.contains("\"durable_round_runtime\":true"))
  }
  @Test fun defaultCreditCapsAreSentRatherThanOmitted() {
    val request = json.encodeToString(PrepareSendReq.serializer(), PrepareSendReq(invoice = "lntbs..."))
    assertTrue(request.contains("\"MaxCreditSat\":10000"))
    assertTrue(request.contains("\"MaxCreditTopupSat\":10000"))
  }
}
