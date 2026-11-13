package engineering.lightning.wavelength.ui

import android.content.Intent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.DiagnosticView
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*
import java.text.DateFormat
import java.util.Date

internal data class DiagnosticRoute(val kind: String, val title: String, val initial: JsonElement = JsonNull,
  val target: String = "", val token: String = "")
internal data class DiagnosticResult(val value: JsonElement = JsonNull, val error: String? = null)

@Composable internal fun diagnosticRead(session: WalletSession, view: DiagnosticView, outpoint: String = "", roundId: String = "",
  history: Boolean = false, pageToken: String = ""): DiagnosticResult {
  var result by remember(view, outpoint, roundId, history, pageToken) { mutableStateOf(DiagnosticResult()) }
  LaunchedEffect(session, view, outpoint, roundId, history, pageToken) {
    while (isActive) {
      try {
        val value = session.inspect { it.diagnosticRead(view, outpoint, roundId, history, pageToken) }
        result = DiagnosticResult(value)
      } catch (error: CancellationException) { throw error }
      catch (error: Exception) { result = result.copy(error = error.message ?: "Read unavailable") }
      delay(8_000)
    }
  }
  return result
}

@Composable internal fun DiagnosticPage(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
  Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
    verticalArrangement = Arrangement.spacedBy(22.dp), content = content)
}
@Composable internal fun DiagnosticLoad(result: DiagnosticResult) {
  if (result.value == JsonNull && result.error == null) CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
  result.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
}
@Composable internal fun DiagnosticCopy(value: String) {
  val clipboard = LocalClipboard.current
  val scope = rememberCoroutineScope()
  IconButton({ scope.launch { clipboard.setClipEntry(ClipEntry(android.content.ClipData.newPlainText("Diagnostics", value))) } }) {
    Icon(Icons.Outlined.ContentCopy, "Copy")
  }
}
@Composable internal fun DiagnosticRaw(value: JsonElement) {
  if (value != JsonNull) DetailSection("Advanced") { DiagnosticCopy(value.pretty)
    SelectionContainer { Text(value.pretty, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
  }
}
@Composable internal fun DiagnosticFields(value: JsonElement) {
  value.fields.toSortedMap().forEach { (key, field) ->
    val label = diagnosticLabel(key)
    if (field is JsonObject || field is JsonArray) DetailSection(label) {
      DiagnosticCopy(field.pretty)
      SelectionContainer { Text(field.pretty, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
    } else if (field.text.length > 35) CopyRow(label, field.text)
    else Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
      Text(label, Modifier.weight(1f)); Text(field.text.ifEmpty { "Not available" }, Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
  }
}
@Composable internal fun DiagnosticShare(text: String) {
  val context = LocalContext.current
  TextButton({ context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, text) }, "Share diagnostics")) }) { Text("Share") }
}
internal fun diagnosticTime(value: Long, milliseconds: Boolean = false): String = if (value <= 0) "Not available" else
  DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.MEDIUM).format(Date(if (milliseconds) value else value * 1000))

/** Block-height or wall-clock boundaries from the native snapshot. */
@Composable internal fun DiagnosticBand(lower: Double, upper: Double, now: Double, opens: Double, closes: Double,
  critical: Double? = null, planned: Double? = null, description: String) {
  val line = MaterialTheme.colorScheme.outlineVariant; val action = MaterialTheme.colorScheme.primary
  val foreground = MaterialTheme.colorScheme.onSurface
  Canvas(Modifier.fillMaxWidth().height(42.dp).semantics { contentDescription = description }) {
    fun x(value: Double) = (((value - lower) / (upper - lower).coerceAtLeast(1.0)).coerceIn(0.0, 1.0) * size.width).toFloat()
    val y = size.height * .6f
    drawLine(line, Offset(0f,y), Offset(size.width,y), 8.dp.toPx(), androidx.compose.ui.graphics.StrokeCap.Round)
    drawLine(action.copy(alpha=.5f), Offset(x(opens),y), Offset(x(closes),y), 8.dp.toPx(), androidx.compose.ui.graphics.StrokeCap.Round)
    if (critical != null) drawLine(Color(0xFFF0A357), Offset(x(critical),y), Offset(x(closes),y), 8.dp.toPx(), androidx.compose.ui.graphics.StrokeCap.Round)
    if (planned != null) drawLine(foreground.copy(alpha=.5f), Offset(x(planned),y-12.dp.toPx()), Offset(x(planned),y+12.dp.toPx()), 2.dp.toPx())
    val marker = x(now).coerceIn(4.dp.toPx(),size.width-4.dp.toPx())
    drawLine(foreground, Offset(marker,y-18.dp.toPx()), Offset(marker,y+6.dp.toPx()), 1.dp.toPx())
    drawCircle(foreground, 3.5.dp.toPx(), Offset(marker,y-18.dp.toPx()))
  }
}
@Composable internal fun ExpiryTimeline(value: JsonElement) {
  val window = ExpiryWindow.from(value)
  if (window == null) Text("Refresh timing unknown", color = MaterialTheme.colorScheme.onSurfaceVariant)
  else Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
    Text("Now ${window.current}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    DiagnosticBand(minOf(window.current, window.refresh).toDouble(), (maxOf(window.expiry, window.current)+1).toDouble(),
      window.current.toDouble(), window.refresh.toDouble(), window.expiry.toDouble(), critical = window.critical.toDouble(),
      description = "Height ${window.current}, refresh from ${window.refresh}, critical from ${window.critical}, expiry ${window.expiry}")
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
      Text("Refresh", style = MaterialTheme.typography.labelSmall)
      Text("Critical", color = Color(0xFFF0A357), style = MaterialTheme.typography.labelSmall)
      Text("Expiry", style = MaterialTheme.typography.labelSmall)
    }
  }
}
@Composable internal fun RoundTimeline(value: JsonElement) {
  val opens = value["registration_opens_unix"].number.toDouble(); val cutoff = value["cutoff_unix"].number.toDouble()
  val planned = value["planned_join_unix_ms"].number.toDouble()/1000
  if (opens <= 0 || cutoff <= opens) return
  var now by remember { mutableDoubleStateOf(System.currentTimeMillis()/1000.0) }
  LaunchedEffect(Unit) { while (isActive) { now = System.currentTimeMillis()/1000.0; delay(1000) } }
  Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
    Text(if (now < opens) "Not open yet" else if (now < cutoff) "Registration open" else "Registration closed", color = MaterialTheme.colorScheme.onSurfaceVariant)
    DiagnosticBand(minOf(now, opens-(cutoff-opens)*.2), maxOf(now,cutoff), now, opens, cutoff, planned = planned.takeIf { it > 0 },
      description = "Opens ${diagnosticTime(opens.toLong())}, cutoff ${diagnosticTime(cutoff.toLong())}, planned join ${diagnosticTime((planned*1000).toLong(), true)}")
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
      Text("Opens", style = MaterialTheme.typography.labelSmall)
      if (planned > 0) Text("Planned join", style = MaterialTheme.typography.labelSmall)
      Text("Cutoff", style = MaterialTheme.typography.labelSmall)
    }
  }
}
