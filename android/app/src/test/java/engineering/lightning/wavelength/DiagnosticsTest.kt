package engineering.lightning.wavelength

import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.DiagnosticLog
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class DiagnosticsTest {
  @Test fun expiryUsesPolicyThresholdsAndPreservesUnknown() {
    val info = Json.parseToJsonElement("""{"current_height":333120,"batch_expiry":333602,"refresh_threshold_blocks":1008,"critical_threshold_blocks":288,"blocks_remaining":482,"status":"VTXO_EXPIRY_STATUS_NEEDS_REFRESH"}""")
    assertEquals(ExpiryWindow(333120,333602,332594,333314), ExpiryWindow.from(info))
    assertTrue(refreshDue(info)); assertEquals("482 blocks left", expiryLabel(info))
    assertNull(ExpiryWindow.from(JsonNull)); assertEquals("Expiry unknown", expiryLabel(JsonNull)); assertFalse(refreshDue(JsonNull))
  }
  @Test fun browsingSurvivesAppendAndNativeEvictionUntilExplicitFollow() {
    fun log(id: String) = DiagnosticLog(id,1,"INFO","ROUND","Quote ready [$id]")
    val before = listOf(log("old"), log("current")); val after = listOf(log("current"),log("new"))
    val window = DiagnosticLogWindow()
    window.browse(before)
    assertEquals(before, window.records(after)); assertFalse(window.following)
    window.browse(after); assertEquals(before, window.records(after))
    window.follow(); assertTrue(window.following); assertEquals(after, window.records(after))
    assertTrue(before.first().matches("quote READY [old]")); assertTrue(before.first().matches("round")); assertFalse(before.first().matches(".*"))
  }
  @Test fun transferDirectionsAndLosslessRawDataArePreserved() {
    val item = Json.parseToJsonElement("""{"direction":"SWAP_DIRECTION_RECEIVE","amount_sat":"9007199254740993"}""")
    assertEquals("Incoming", transferDirection(item)); assertEquals(9007199254740993L,item["amount_sat"].number)
    assertTrue(item.pretty.contains("\"9007199254740993\""))
    assertEquals("Direction unknown",transferDirection(JsonNull))
    assertEquals("Failed before funds were committed",diagnosticLabel("failed_before_ponr"))
  }
  @Test fun hostRunsAreBoundedAndKeepFirstTerminalResult() {
    val runs = DiagnosticRuns()
    repeat(40) { runs.begin(WalletNetwork.SIGNET); runs.stage("Wallet available"); runs.stage("Wallet available"); runs.finish("Paused") }
    runs.finish("Superseded")
    assertEquals(32,runs.runs.value.size)
    assertEquals(listOf("Foreground requested","Wallet available","Paused"),runs.runs.value.last().stages.map { it.label })
    assertTrue(runs.runs.value.last().ended)
  }
  @Test fun captureLevelReachesTheNativeConfig() {
    assertEquals("info",NetworkSettings().config(WalletNetwork.SIGNET,"/wallet").debugLevel)
    assertEquals("trace",NetworkSettings().config(WalletNetwork.SIGNET,"/wallet",CaptureLevel.TRACE).debugLevel)
  }
}
