package engineering.lightning.wavelength.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.DiagnosticLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.serialization.json.*

@Composable internal fun DiagnosticLogs(session: WalletSession, initialQuery: String, modifier: Modifier, navigate: (DiagnosticRoute) -> Unit) {
  val state by session.state.collectAsStateWithLifecycle()
  val query = rememberTextFieldState(initialQuery)
  var level by remember { mutableStateOf("All levels") }
  var source by remember { mutableStateOf("All sources") }
  var paused by remember { mutableStateOf(false) }
  var following by remember { mutableStateOf(true) }
  var live by remember { mutableStateOf<List<DiagnosticLog>>(emptyList()) }
  var error by remember { mutableStateOf<String?>(null) }
  var historyUnavailable by remember { mutableStateOf(false) }
  val window = remember { DiagnosticLogWindow() }
  val scroll = rememberLazyListState()
  val currentLive by rememberUpdatedState(live)
  val currentPaused by rememberUpdatedState(paused)
  LaunchedEffect(session) {
    while (isActive) {
      if (!currentPaused) {
        try {
          val snapshot = session.inspect { it.diagnosticLogs() }
          live = snapshot.entries.orEmpty(); historyUnavailable = snapshot.historyUnavailable; error = null
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { error = e.message ?: "Logs unavailable" }
      }
      delay(1000)
    }
  }
  LaunchedEffect(scroll) {
    scroll.interactionSource.interactions.collect { interaction ->
      if (interaction is DragInteraction.Start) { window.browse(currentLive); following = false }
    }
  }
  fun matches(record: DiagnosticLog) = record.matches(query.text.toString()) &&
    (level == "All levels" || level == record.level) && (source == "All sources" || source == record.source)
  val shown = (if (following) live else window.records(live)).filter(::matches)
  val count = live.count(::matches)
  LaunchedEffect(shown.lastOrNull()?.id, following) { if (following && shown.isNotEmpty()) scroll.scrollToItem(shown.lastIndex) }
  Column(modifier.fillMaxSize().padding(horizontal = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
      Text("Capture level", style = MaterialTheme.typography.labelMedium)
      LogFilter(state.captureLevel.title, CaptureLevel.entries.map { it.title }) { title -> session.setCaptureLevel(CaptureLevel.entries.first { it.title == title }) }
    }
    Text("Applies on the next wallet startup.", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    WalletField("Filter logs", query)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
      LogFilter(level, listOf("All levels", "TRACE", "DEBUG", "INFO", "WARN", "ERROR")) { level = it }
      LogFilter(source, listOf("All sources") + live.map { it.source }.distinct().sorted()) { source = it }
    }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
      Text(if (paused) "Paused" else if (following) "Live" else "Browsing", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
      Spacer(Modifier.weight(1f))
      Text("$count matches", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelMedium)
      IconButton({ paused = !paused }) { Icon(if (paused) Icons.Outlined.PlayArrow else Icons.Outlined.Pause, if (paused) "Resume logs" else "Pause logs") }
    }
    error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    if (historyUnavailable) Text("Earlier log history is unavailable.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    LazyColumn(Modifier.weight(1f), state = scroll, verticalArrangement = Arrangement.spacedBy(16.dp), contentPadding = PaddingValues(bottom = 20.dp)) {
      items(shown, key = { it.id }) { record ->
        Column(Modifier.fillMaxWidth().clickable {
          navigate(DiagnosticRoute("log", "Log entry", buildJsonObject {
            put("time", diagnosticTime(record.time,true)); put("level", record.level); put("source", record.source); put("message", record.message)
          }))
        }, verticalArrangement = Arrangement.spacedBy(7.dp)) {
          Text("${diagnosticTime(record.time,true)}  ${record.level}  ${record.source}", fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
          Text(highlightLog(record.message, query.text.toString()), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, maxLines = 4)
          HorizontalDivider(Modifier.padding(top = 8.dp))
        }
      }
      if (shown.isEmpty()) item { Text(if (live.isEmpty()) "No captured logs yet" else "No matches", color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
    Row(Modifier.fillMaxWidth().padding(bottom = 12.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
      TextButton({ window.follow(); following = true }) { Text("Follow latest") }
      DiagnosticShare(shown.joinToString("\n") { "${diagnosticTime(it.time,true)} ${it.level} ${it.source} ${it.message}" })
    }
  }
}

@Composable private fun LogFilter(selected: String, values: List<String>, select: (String) -> Unit) {
  var open by remember { mutableStateOf(false) }
  Box {
    TextButton({ open = true }) { Text(selected) }
    DropdownMenu(open, { open = false }) {
      values.forEach { value -> DropdownMenuItem({ Text(value) }, { select(value); open = false }) }
    }
  }
}

@Composable private fun highlightLog(message: String, query: String): AnnotatedString {
  if (query.isEmpty()) return AnnotatedString(message)
  val highlight = MaterialTheme.colorScheme.primary.copy(alpha = .25f)
  return buildAnnotatedString {
    var cursor = 0
    while (cursor < message.length) {
      val match = message.indexOf(query, cursor, ignoreCase = true)
      if (match < 0) { append(message.substring(cursor)); break }
      append(message.substring(cursor, match))
      withStyle(SpanStyle(background = highlight)) { append(message.substring(match, match + query.length)) }
      cursor = match + query.length
    }
  }
}
