package engineering.lightning.wavelength.background

import android.util.AtomicFile
import engineering.lightning.wavelength.data.WalletNetwork
import engineering.lightning.wavewalletdk.client.MaintenanceResult
import engineering.lightning.wavewalletdk.client.DiagnosticLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

@Serializable data class BackgroundWakeContext(val entryPoint: String, val taskId: String? = null,
  val attempt: Int? = null)
@Serializable data class BackgroundNativeWork(val batches: Int, val checked: Int,
  val deferred: Boolean, val more: Boolean, val needsForeground: Boolean,
  val interrupted: Boolean, val budgetExhausted: Boolean,
  val receiptProofs: Int? = null, val completeProofs: Int? = null)
@Serializable data class BackgroundStage(val label: String, val time: Long = System.currentTimeMillis(),
  val elapsedMilliseconds: Long? = null, val durationMilliseconds: Long? = null)
@Serializable data class BackgroundRun(val id: String, val network: String, val trigger: String,
  val stages: List<BackgroundStage>, val outcome: String? = null,
  val wake: BackgroundWakeContext? = null, val startup: String? = null,
  val finished: Long? = null, val durationMilliseconds: Long? = null,
  val hostBudgetSeconds: Int? = null, val nativeBudgetSeconds: Int? = null,
  val native: BackgroundNativeWork? = null) {
  val logUntil: Long? get() = if (outcome == null) null else maxOf(finished ?: stages.last().time,stages.last().time)
}

/** Bounded host evidence across process death; no tokens, invoices or secrets. */
class BackgroundJournal(file: File, private val uptime: () -> Long = { android.os.SystemClock.elapsedRealtime() }) {
  private val file = AtomicFile(file)
  private val json = Json { ignoreUnknownKeys = true }
  private val mutable = MutableStateFlow(load().map { run -> if (run.outcome == null) run.copy(outcome = "End not recorded") else run })
  val runs = mutable.asStateFlow()
  private val beganAt = mutableMapOf<String,Long>()
  private fun load(): List<BackgroundRun> = runCatching {
    if (file.baseFile.exists() || java.io.File(file.baseFile.path + ".bak").exists()) json.decodeFromString<List<BackgroundRun>>(file.readFully().toString(Charsets.UTF_8)) else emptyList()
  }.getOrDefault(emptyList())
  private fun save(value: List<BackgroundRun>) {
    // Diagnostics failures never prevent wallet recovery.
    mutable.value = value.takeLast(32)
    runCatching {
      file.baseFile.parentFile?.mkdirs()
      val out = file.startWrite()
      try { out.write(json.encodeToString(kotlinx.serialization.builtins.ListSerializer(BackgroundRun.serializer()),mutable.value).toByteArray()); file.finishWrite(out) }
      catch (error: Throwable) { file.failWrite(out); throw error }
    }
  }
  fun begin(id: String, network: WalletNetwork, trigger: String, wake: BackgroundWakeContext? = null) {
    beganAt[id] = uptime()
    save(mutable.value + BackgroundRun(id,network.wire,trigger,listOf(BackgroundStage("Opportunity started",elapsedMilliseconds = 0)),wake = wake,hostBudgetSeconds = 20))
    beganAt.keys.retainAll(mutable.value.map { it.id }.toSet())
  }
  fun stage(id: String, label: String, duration: Long? = null) = save(mutable.value.map {
    if (it.id == id) it.copy(stages = (it.stages + BackgroundStage(label,elapsedMilliseconds = elapsed(id),durationMilliseconds = duration)).takeLast(64)) else it
  })
  private fun elapsed(id: String) = beganAt[id]?.let { (uptime()-it).coerceAtLeast(0) }
  fun mark() = uptime()
  fun duration(start: Long) = (uptime()-start).coerceAtLeast(0)
  suspend fun <T> measure(id: String, label: String, operation: suspend () -> T): T {
    val start = uptime()
    try { return operation().also { stage(id,label,duration(start)) } }
    catch (error: Exception) { stage(id,"$label failed",duration(start)); throw error }
  }
  fun context(id: String, startup: String? = null, nativeBudget: Int? = null) = save(mutable.value.map {
    if (it.id == id) it.copy(startup = startup ?: it.startup,nativeBudgetSeconds = nativeBudget ?: it.nativeBudgetSeconds) else it
  })
  fun nativeResult(id: String, result: MaintenanceResult) = save(mutable.value.map {
    if (it.id == id) it.copy(native = BackgroundNativeWork(result.batches,result.maintenanceChecked,
      result.maintenanceDeferred,result.maintenanceMore,result.needsForeground,result.interrupted,result.budgetExhausted)) else it
  })
  fun receipts(id: String, proofs: Int, complete: Int) = save(mutable.value.map {
    if (it.id == id) it.copy(native = it.native?.copy(receiptProofs = proofs,completeProofs = complete)) else it
  })
  fun finish(id: String, outcome: String) = save(mutable.value.map {
    if (it.id == id && it.outcome == null) it.copy(outcome = outcome,finished = System.currentTimeMillis(),durationMilliseconds = elapsed(id)) else it
  })
  fun hostLogs(network: String): List<DiagnosticLog> = mutable.value.filter { it.network == network }.flatMap { run ->
    run.stages.mapIndexed { index,event -> DiagnosticLog("${run.id}:$index",event.time,"INFO","App/$network","${event.label} [${run.id}]" + (event.durationMilliseconds?.let { " ($it ms)" } ?: "")) }
  }.takeLast(512)
}
