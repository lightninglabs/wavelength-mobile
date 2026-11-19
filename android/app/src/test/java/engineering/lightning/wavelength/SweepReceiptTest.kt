package engineering.lightning.wavelength

import engineering.lightning.wavewalletdk.client.*
import kotlinx.coroutines.test.runTest
import engineering.lightning.wavelength.ui.*
import org.junit.Assert.*
import org.junit.Test

class SweepReceiptTest {
  @Test fun confirmationChecksAgainIfRecoveryStartedAfterPreview() = runTest {
    var exits = ExitSummary()
    var quotes = 0
    suspend fun quote() = checkedSweepPreview({ exits }) {
      quotes++
      SweepPreview(3000, 100, 2900, 1, true, "", "")
    }
    assertTrue(quote().canBroadcast)
    exits = ExitSummary(listOf(ExitSummaryEntry("output:0", "in_progress", 2500)))
    assertTrue(runCatching { quote() }.exceptionOrNull() is IllegalStateException)
    assertEquals(1, quotes)
    val unavailable = runCatching {
      checkedSweepPreview({ error("offline") }) { quote() }
    }
    assertEquals("offline", unavailable.exceptionOrNull()?.message)
    assertEquals(1, quotes)
  }

  @Test fun historyOnlyConfirmsTheExactBroadcast() {
    val receipt = SweepReceipt("host-id", "address", 2000, 3)
    val history = listOf(OnchainTx(txid = "abc", status = "confirmed", amountSat = 2000))
    assertFalse(receipt.checked(history).confirmed)
    assertFalse(receipt.copy(txid = "other").checked(history).confirmed)
    assertTrue(receipt.copy(txid = "abc").checked(history).confirmed)
    assertEquals(2, receipt.checked(history).checked(history).checked(history).checks)
  }
}
