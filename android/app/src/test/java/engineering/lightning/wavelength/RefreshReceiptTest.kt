package engineering.lightning.wavelength

import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.RefreshObservation
import engineering.lightning.wavewalletdk.client.WalletVTXO
import org.junit.Assert.*
import org.junit.Test

class RefreshReceiptTest {
  @Test fun onlyAuthoritativeRemainingInputsCanStartAnotherPreview() {
    val receipt = RefreshReceipt(listOf("a:0", "b:0"), 2800)
    val partial = RefreshObservation(false, true, 1, 1800, listOf("b:0"), 1000)
    assertEquals(listOf("b:0"), partial.retrySelection(receipt))
    assertNull(partial.copy(retryAllowed = false).retrySelection(receipt))
    assertNull(partial.copy(remaining = emptyList()).retrySelection(receipt))
    assertNull(partial.copy(remaining = listOf("c:0")).retrySelection(receipt))
    assertEquals(emptyList<String>(), partial.copy(complete = true).retrySelection(receipt))
  }

  @Test fun groupsFundsByEstimatedExpiryWithSoonestFirst() {
    val funds = listOf(
      WalletVTXO("a:0", 1200, "live", 302),
      WalletVTXO("b:0", 300, "live", 0),
      WalletVTXO("c:0", 500, "expired", 0),
      WalletVTXO("d:0", 600, "live", 113),
      WalletVTXO("e:0", 700, "live", 111),
    )
    assertEquals(listOf(
      RefreshExpiryGroup("Expired", 500),
      RefreshExpiryGroup("In about 2 hours", 1300),
      RefreshExpiryGroup("In about 1 day", 1200),
      RefreshExpiryGroup("Expiry unavailable", 300),
    ), refreshExpiryGroups(funds, 100))
  }
}
