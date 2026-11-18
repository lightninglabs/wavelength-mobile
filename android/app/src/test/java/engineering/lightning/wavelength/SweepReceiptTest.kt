package engineering.lightning.wavelength

import engineering.lightning.wavewalletdk.client.OnchainTx
import engineering.lightning.wavelength.ui.*
import org.junit.Assert.*
import org.junit.Test

class SweepReceiptTest {
  @Test fun historyOnlyConfirmsTheExactBroadcast() {
    val receipt = SweepReceipt("host-id", "address", 2000, 3)
    val history = listOf(OnchainTx(txid = "abc", status = "confirmed", amountSat = 2000))
    assertFalse(receipt.checked(history).confirmed)
    assertFalse(receipt.copy(txid = "other").checked(history).confirmed)
    assertTrue(receipt.copy(txid = "abc").checked(history).confirmed)
    assertEquals(2, receipt.checked(history).checked(history).checked(history).checks)
  }
}
