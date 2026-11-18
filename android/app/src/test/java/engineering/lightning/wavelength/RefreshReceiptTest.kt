package engineering.lightning.wavelength

import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.RefreshObservation
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
}
