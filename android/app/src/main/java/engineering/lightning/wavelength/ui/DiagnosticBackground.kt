package engineering.lightning.wavelength.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import engineering.lightning.wavelength.BuildConfig
import engineering.lightning.wavelength.background.*
import engineering.lightning.wavelength.data.WalletSession
import kotlinx.serialization.json.Json

@Composable internal fun DiagnosticBackground(session: WalletSession, modifier: Modifier, navigate: (DiagnosticRoute) -> Unit) {
  val runs by session.backgroundHistory.runs.collectAsStateWithLifecycle()
  val state by session.state.collectAsStateWithLifecycle()
  val context = LocalContext.current
  var queued by remember { mutableStateOf(false) }
  DiagnosticPage(modifier) {
    Text("Host wake reasons and measured work. Android does not expose why it chose a delivery time.",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (BuildConfig.DEBUG) {
      WalletButton("Schedule a check",secondary = true) { WalletWork.opportunity(context,"Developer check",delaySeconds = 5);queued = true }
      if (queued) Text("Starts after 5 seconds. Leave the app in the background.",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    val selected = runs.filter { it.network == state.network.wire }.asReversed()
    if (selected.isEmpty()) Text("No background runs recorded",color = MaterialTheme.colorScheme.onSurfaceVariant)
    selected.forEach { run ->
      Row(Modifier.fillMaxWidth().clickable { navigate(DiagnosticRoute("backgroundRun","Background run",target = run.id)) }.padding(vertical = 12.dp),verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f),verticalArrangement = Arrangement.spacedBy(8.dp)) {
          Text(run.trigger,style = MaterialTheme.typography.titleMedium)
          Text("${diagnosticTime(run.stages.first().time,true)} · ${run.outcome ?: "Running"}",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        run.durationMilliseconds?.let { Text("${it/1000.0}s",style = MaterialTheme.typography.labelMedium) }
        Icon(Icons.Outlined.ChevronRight,null,Modifier.padding(start = 8.dp).size(18.dp))
      }
      HorizontalDivider()
    }
  }
}

@Composable internal fun DiagnosticBackgroundRun(session: WalletSession, id: String, modifier: Modifier, navigate: (DiagnosticRoute) -> Unit) {
  val runs by session.backgroundHistory.runs.collectAsStateWithLifecycle()
  val state by session.state.collectAsStateWithLifecycle()
  val run = runs.firstOrNull { it.id == id && it.network == state.network.wire }
  DiagnosticPage(modifier) {
    if (run == null) { Text("This run is no longer retained."); return@DiagnosticPage }
    run.durationMilliseconds?.let { Text("${it/1000.0}s",style = MaterialTheme.typography.headlineLarge) }
    Text(run.outcome ?: "Running",color = MaterialTheme.colorScheme.onSurfaceVariant)
    SettingsValue("Wake reason",run.trigger)
    SettingsValue("Entry point",run.wake?.entryPoint ?: "Not recorded")
    SettingsValue("Startup",run.startup ?: "Not recorded")
    run.wake?.attempt?.let { SettingsValue("Work attempt",(it+1).toString()) }
    run.hostBudgetSeconds?.let { SettingsValue("Overall time limit","$it s") }
    run.nativeBudgetSeconds?.let { SettingsValue("SDK work limit","$it s") }
    run.stages.lastOrNull()?.elapsedMilliseconds?.let { last ->
      if (run.durationMilliseconds != null && last > run.durationMilliseconds + 1) SettingsValue("Last observation","${last/1000.0}s")
    }
    run.native?.let { native ->
      HorizontalDivider()
      Text("Work observed",style = MaterialTheme.typography.titleMedium)
      SettingsValue("Mailbox batches",native.batches.toString())
      SettingsValue("VTXO owners checked",native.checked.toString())
      native.receiptProofs?.let { SettingsValue("Receipt proofs",it.toString()) }
      native.completeProofs?.let { SettingsValue("Complete proofs",it.toString()) }
      if (native.deferred) SettingsValue("Maintenance","Deferred")
      if (native.more) SettingsValue("Maintenance","More work remains")
      if (native.needsForeground) SettingsValue("Foreground","Required")
      if (native.interrupted) SettingsValue("Native result","Interrupted")
      if (native.budgetExhausted) SettingsValue("SDK work limit","Exhausted")
      Text("Mailbox batches count nonempty dispatch attempts. These counters do not prove a round completed.",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    HorizontalDivider()
    Text("Timeline",style = MaterialTheme.typography.titleMedium)
    val line = MaterialTheme.colorScheme.outlineVariant;val action = MaterialTheme.colorScheme.primary
    run.stages.forEachIndexed { index,stage ->
      Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        androidx.compose.foundation.Canvas(Modifier.width(18.dp).height(56.dp)) {
          val x=size.width/2;val y=9.dp.toPx()
          if (index>0) drawLine(line,androidx.compose.ui.geometry.Offset(x,0f),androidx.compose.ui.geometry.Offset(x,y),2.dp.toPx())
          if (index<run.stages.lastIndex) drawLine(line,androidx.compose.ui.geometry.Offset(x,y),androidx.compose.ui.geometry.Offset(x,size.height+22.dp.toPx()),2.dp.toPx())
          drawCircle(action,4.dp.toPx(),androidx.compose.ui.geometry.Offset(x,y))
        }
        Column(Modifier.weight(1f),verticalArrangement = Arrangement.spacedBy(5.dp)) {
          Text(stage.label,style = MaterialTheme.typography.bodyMedium)
          val elapsed = stage.elapsedMilliseconds ?: (stage.time-run.stages.first().time)
          Text("+${elapsed/1000.0}s" + (stage.durationMilliseconds?.let { " · took ${it/1000.0}s" } ?: ""),style = MaterialTheme.typography.labelSmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
      }
    }
    CopyRow("Window ID",run.id)
    run.wake?.taskId?.let { CopyRow("Work request ID",it) }
    WalletButton("View related logs",secondary = true) { navigate(DiagnosticRoute("logs","Run logs",since = run.stages.first().time,until = run.logUntil)) }
    DiagnosticShare(Json { prettyPrint = true }.encodeToString(BackgroundRun.serializer(),run))
  }
}
