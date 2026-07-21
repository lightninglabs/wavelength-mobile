package engineering.lightning.wavewalletdk.client

import kotlinx.serialization.json.Json
import org.junit.Assert.assertTrue
import org.junit.Test

class WalletConfigTest {
  private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

  @Test
  fun signetEncodesOperatorAndEsplora() {
    val s = json.encodeToString(
      WalletConfig.serializer(),
      WalletConfig.signet(dataDir = "/tmp/wallet"),
    )
    assertTrue("missing server_address: $s", s.contains("\"server_address\""))
    assertTrue("missing operator host: $s", s.contains("arkd-signet"))
    assertTrue("missing esplora: $s", s.contains("mempool.space/signet"))
    assertTrue("missing network: $s", s.contains("\"network\":\"signet\""))
  }
}
