package engineering.lightning.wavelength.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import engineering.lightning.wavelength.data.WalletSession

@Composable internal fun DiagnosticHostRuns(session: WalletSession, modifier: Modifier) {
  val runs by session.diagnostics.runs.collectAsStateWithLifecycle()
  val state by session.state.collectAsStateWithLifecycle()
  DiagnosticPage(modifier) {
    Text("Foreground activity", style = MaterialTheme.typography.titleLarge)
    Text("Foreground stages for this process. Scheduled work is recorded under Background.", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
    runs.filter { it.network == state.network }.asReversed().forEach { run ->
      val first = run.stages.first().time
      DetailSection("${diagnosticTime(first,true)} · ${if (run.ended) run.stages.last().label else "Running"}") {
        val line = MaterialTheme.colorScheme.outlineVariant
        val action = MaterialTheme.colorScheme.primary
        run.stages.forEachIndexed { index, stage ->
          Row(Modifier.fillMaxWidth().heightIn(min = 56.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Canvas(Modifier.width(18.dp).height(56.dp)) {
              val x = size.width/2; val y = 9.dp.toPx()
              if (index > 0) drawLine(line, Offset(x,0f), Offset(x,y), 2.dp.toPx())
              if (index < run.stages.lastIndex) drawLine(line, Offset(x,y), Offset(x,size.height+20.dp.toPx()), 2.dp.toPx())
              drawCircle(action,4.dp.toPx(),Offset(x,y))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
              Text(stage.label, style = MaterialTheme.typography.bodyMedium)
              Text("+${(stage.time-first)/1000.0}s", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
          }
        }
      }
      HorizontalDivider()
    }
  }
}
