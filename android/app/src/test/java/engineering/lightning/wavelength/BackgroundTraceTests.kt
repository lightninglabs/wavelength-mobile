package engineering.lightning.wavelength

import engineering.lightning.wavelength.background.*
import engineering.lightning.wavelength.data.inTimeWindow
import engineering.lightning.wavelength.ui.diagnosticTime
import engineering.lightning.wavewalletdk.client.DiagnosticLog
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.text.DateFormat
import java.util.Date

class BackgroundTraceTests {
  @Test fun optionalProducerMetadataDescribesOnlyKnownWakeReasons() {
    val legacy = BackgroundRun("id", "signet", "Push wake", listOf(BackgroundStage("Started", 1000)))
    assertEquals("Relay wake", legacy.wakeTitle)
    assertTrue(legacy.wakeReasonUnavailable)
    assertNull(BackgroundProducerWake.parse(null, "1800000000"))
    assertNull(BackgroundProducerWake.parse("future", "1800000000"))
    for (invalid in listOf("0", "-1", "1.25", "9999999999999999")) {
      val signing = BackgroundProducerWake.parse("round_signing", invalid)!!
      assertEquals(BackgroundProducerWake.Reason.ROUND_SIGNING, signing.reason)
      assertNull(signing.deadline)
    }
    val scheduled = BackgroundProducerWake.parse("scheduled_round", "1800000000")!!
    val run = legacy.copy(wake = BackgroundWakeContext("WorkManager one-time", producer = scheduled))
    val restored = Json.decodeFromString<BackgroundRun>(Json.encodeToString(BackgroundRun.serializer(), run))
    assertEquals("Scheduled round", restored.wakeTitle)
    assertEquals(1_800_000_000L, restored.wake?.producer?.deadline)
    val rendered = diagnosticTime(restored.wake!!.producer!!.deadline!!,milliseconds = false)
    assertEquals(DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.MEDIUM)
      .format(Date(1_800_000_000_000L)), rendered)
    assertFalse(restored.wakeReasonUnavailable)
    assertNull(BackgroundProducerWake.parse("mailbox_update", "1800000000")!!.deadline)
  }

  @Test fun legacyRunRemainsReadableWithoutInventingMeasurements() {
    val run = Json.decodeFromString<BackgroundRun>("""{"id":"old","network":"signet","trigger":"Scheduled","stages":[{"label":"Start","time":1000},{"label":"Native returned","time":2000}],"outcome":"Interrupted"}""")
    assertNull(run.wake);assertNull(run.startup);assertNull(run.native)
    assertNull(run.stages[0].durationMilliseconds);assertEquals(2000L,run.logUntil)
  }
  @Test fun traceRoundTripsCountersAndKeepsCleanupInsideRelatedLogRange() {
    val native = BackgroundNativeWork(8,4,true,true,true,true,false,3,2)
    val run = BackgroundRun("run","signet","Payment hint",listOf(
      BackgroundStage("Native entered",1000,0),BackgroundStage("Late native return",3000,2000,1500)),
      "Window expired",BackgroundWakeContext("WorkManager one-time","worker",1),"Cold",2000,1000,20,15,native)
    val decoded = Json.decodeFromString<BackgroundRun>(Json.encodeToString(BackgroundRun.serializer(),run))
    assertEquals(run,decoded);assertEquals(3000L,decoded.logUntil)
    assertEquals("Window expired",decoded.outcome);assertEquals(8,decoded.native!!.batches)
    assertEquals(2,decoded.native.completeProofs)
    assertNull(decoded.copy(outcome=null).logUntil)
  }
  @Test fun relatedLogRangeIsInclusiveAndSupportsRunningWindow() {
    fun log(time: Long) = DiagnosticLog("$time",time,"INFO","ROUND","quote")
    assertFalse(log(999).inTimeWindow(1000,2000))
    assertTrue(log(1000).inTimeWindow(1000,2000));assertTrue(log(2000).inTimeWindow(1000,2000))
    assertFalse(log(2001).inTimeWindow(1000,2000));assertTrue(log(3000).inTimeWindow(1000,null))
  }
}
