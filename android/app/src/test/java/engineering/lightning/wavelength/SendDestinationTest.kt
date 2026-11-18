package engineering.lightning.wavelength

import engineering.lightning.wavelength.data.*
import org.junit.Assert.*
import org.junit.Test

class SendDestinationTest {
  @Test fun bitcoinUriBindsWholeSatsAndPrefersLightning() {
    assertEquals(SendDestination("tb1abc", false, 1001), SendDestination.parse("bitcoin:tb1abc?amount=0.00001001"))
    assertEquals(SendDestination("lntbs1abc", true), SendDestination.parse("BITCOIN:tb1abc?lightning=lightning%3Alntbs1abc"))
    listOf("amount=0.000000001", "amount=1&amount=2", "req-custom=a").forEach { query ->
      assertTrue(runCatching { SendDestination.parse("bitcoin:tb1abc?$query") }.isFailure)
    }
    listOf("1.5", "+1", "-1", "2100000000000001").forEach { assertNull(wholeSats(it)) }
  }
}
