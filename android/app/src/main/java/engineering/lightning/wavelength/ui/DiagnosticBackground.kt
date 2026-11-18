package engineering.lightning.wavelength.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import engineering.lightning.wavelength.BuildConfig
import engineering.lightning.wavelength.background.WalletWork
import engineering.lightning.wavelength.data.WalletSession

@Composable internal fun DiagnosticBackground(session: WalletSession, modifier: Modifier) {
  val runs by session.backgroundHistory.runs.collectAsStateWithLifecycle()
  val state by session.state.collectAsStateWithLifecycle()
  val context = LocalContext.current
  var queued by remember { mutableStateOf(false) }
  DiagnosticPage(modifier) {
    Text("Background opportunities",style = MaterialTheme.typography.titleLarge)
    Text("Actual host entry points and native window results. Android controls timing.",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (BuildConfig.DEBUG) {
      WalletButton("Schedule a check",secondary = true) { WalletWork.opportunity(context,"Developer check",delaySeconds = 5);queued = true }
      if (queued) Text("Starts after 5 seconds. Leave the app in the background.",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    val selected = runs.filter { it.network == state.network.wire }.asReversed()
    if (selected.isEmpty()) Text("No background runs recorded",color = MaterialTheme.colorScheme.onSurfaceVariant)
    selected.forEach { run ->
      DetailSection("${diagnosticTime(run.stages.first().time,true)} · ${run.outcome ?: "Running"}") {
        SettingsValue("Trigger",run.trigger)
        val line = MaterialTheme.colorScheme.outlineVariant;val action = MaterialTheme.colorScheme.primary
        run.stages.forEachIndexed { index,stage ->
          Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            androidx.compose.foundation.Canvas(Modifier.width(18.dp).height(56.dp)) {
              val x=size.width/2;val y=9.dp.toPx()
              if (index>0) drawLine(line,androidx.compose.ui.geometry.Offset(x,0f),androidx.compose.ui.geometry.Offset(x,y),2.dp.toPx())
              if (index<run.stages.lastIndex) drawLine(line,androidx.compose.ui.geometry.Offset(x,y),androidx.compose.ui.geometry.Offset(x,size.height+20.dp.toPx()),2.dp.toPx())
              drawCircle(action,4.dp.toPx(),androidx.compose.ui.geometry.Offset(x,y))
            }
            Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
              Text(stage.label,style = MaterialTheme.typography.bodyMedium)
              Text("+${(stage.time-run.stages.first().time)/1000.0}s",style = MaterialTheme.typography.labelSmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
          }
        }
      }
      HorizontalDivider()
    }
  }
}
