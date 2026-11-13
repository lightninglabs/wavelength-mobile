package engineering.lightning.wavelength.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Actual host stages for this process, scoped to a network. No wallet secrets. */
data class DiagnosticStage(val label: String, val time: Long = System.currentTimeMillis())
data class DiagnosticRun(val id: Long, val network: WalletNetwork, val stages: List<DiagnosticStage>, val ended: Boolean = false)
class DiagnosticRuns {
  private val mutable = MutableStateFlow<List<DiagnosticRun>>(emptyList())
  val runs = mutable.asStateFlow()
  private var next = 0L
  fun begin(network: WalletNetwork) {
    finish("Superseded")
    mutable.update { (it + DiagnosticRun(++next, network, listOf(DiagnosticStage("Foreground requested")))).takeLast(32) }
  }
  fun stage(label: String) = mutable.update { all ->
    val last = all.lastOrNull() ?: return@update all
    if (last.ended || last.stages.any { it.label == label }) all
    else all.dropLast(1) + last.copy(stages = (last.stages + DiagnosticStage(label)).takeLast(16))
  }
  fun finish(label: String) {
    stage(label)
    mutable.update { all -> all.lastOrNull()?.let { all.dropLast(1) + it.copy(ended = true) } ?: all }
  }
}
