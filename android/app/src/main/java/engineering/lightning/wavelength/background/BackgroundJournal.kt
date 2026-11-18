package engineering.lightning.wavelength.background

import android.util.AtomicFile
import engineering.lightning.wavelength.data.WalletNetwork
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

@Serializable data class BackgroundStage(val label: String, val time: Long = System.currentTimeMillis())
@Serializable data class BackgroundRun(val id: String, val network: String, val trigger: String,
  val stages: List<BackgroundStage>, val outcome: String? = null)

/** Bounded host evidence across process death; no tokens, invoices or secrets. */
class BackgroundJournal(file: File) {
  private val file = AtomicFile(file)
  private val json = Json { ignoreUnknownKeys = true }
  private val mutable = MutableStateFlow(load().map { run -> if (run.outcome == null) run.copy(outcome = "End not recorded") else run })
  val runs = mutable.asStateFlow()
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
  fun begin(id: String, network: WalletNetwork, trigger: String) = save(mutable.value + BackgroundRun(id,network.wire,trigger,listOf(BackgroundStage("Opportunity started"))))
  fun stage(id: String, label: String) = save(mutable.value.map { if (it.id == id && it.outcome == null) it.copy(stages = (it.stages + BackgroundStage(label)).takeLast(16)) else it })
  fun finish(id: String, outcome: String) = save(mutable.value.map { if (it.id == id && it.outcome == null) it.copy(outcome = outcome) else it })
}
