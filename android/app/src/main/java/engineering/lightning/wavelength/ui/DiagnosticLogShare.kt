package engineering.lightning.wavelength.ui

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import engineering.lightning.wavewalletdk.client.DiagnosticLog
import engineering.lightning.wavelength.data.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

private data class LogShareSnapshot(val records: List<DiagnosticLog>, val network: String, val interval: Boolean)

internal fun diagnosticLogFileIntent(context: Context, file: File, mime: String): Intent {
  val uri = FileProvider.getUriForFile(context, "${context.packageName}.diagnostic-exports", file)
  return Intent(Intent.ACTION_SEND).apply {
    type = mime; putExtra(Intent.EXTRA_STREAM, uri)
    clipData = ClipData.newRawUri(file.name, uri)
    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
  }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun DiagnosticLogShare(records: List<DiagnosticLog>, network: String, interval: Boolean,
  launchChooser: ((Intent) -> Unit)? = null) {
  val context = LocalContext.current
  var snapshot by remember { mutableStateOf<LogShareSnapshot?>(null) }
  var text by remember { mutableStateOf<String?>(null) }
  var files by remember { mutableStateOf<DiagnosticLogFiles?>(null) }
  var error by remember { mutableStateOf<String?>(null) }
  fun launch(intent: Intent) {
    val chooser = Intent.createChooser(intent, null)
    if (launchChooser != null) launchChooser(chooser) else context.startActivity(chooser)
  }
  fun shareText(value: String) {
    launch(Intent(Intent.ACTION_SEND).apply {
      type = "text/plain"; putExtra(Intent.EXTRA_TEXT, value)
    })
  }
  fun shareFile(file: File, mime: String) {
    launch(diagnosticLogFileIntent(context, file, mime))
  }
  fun launchShare(action: () -> Unit): Boolean =
    try { action(); snapshot = null; true }
    catch (e: Exception) { error = "Couldn’t share logs. ${e.message.orEmpty()}"; false }
  TextButton(enabled = records.isNotEmpty(), onClick = {
    text = null; files = null; error = null
    snapshot = LogShareSnapshot(records.toList(), network, interval)
  }) { Text("Share") }
  LaunchedEffect(snapshot) {
    val captured = snapshot ?: return@LaunchedEffect
    // Keep presentation state and chooser launches on Main across IO work.
    withContext(Dispatchers.Main.immediate) {
      try {
        val value = withContext(Dispatchers.Default) { exportLogText(captured.records) }
        text = value
        // Binder has a transaction-size limit. Large intervals use the same file
        // choices as all logs instead of failing to open the system chooser.
        val sent = captured.interval && value.length <= MAX_INLINE_LOG_CHARACTERS && launchShare { shareText(value) }
        if (!sent) {
          files = withContext(Dispatchers.IO) {
            DiagnosticLogFiles.prepare(value, captured.network, File(context.cacheDir, "diagnostic-exports"))
          }
        }
      } catch (e: CancellationException) { throw e }
      catch (e: Exception) { error = "Couldn’t prepare logs. ${e.message.orEmpty()}" }
    }
  }
  if (snapshot != null) ModalBottomSheet(onDismissRequest = { snapshot = null }) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp)) {
      Text("Share logs", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(bottom = 20.dp))
      val prepared = files
      if (prepared != null) {
        LogShareRow("Share ZIP", "Compressed file · ${Formatter.formatShortFileSize(context, prepared.zip.length())}",
          { Icon(Icons.Outlined.Archive, null, tint = MaterialTheme.colorScheme.primary) }) {
          launchShare { shareFile(prepared.zip, "application/zip") }
        }
        HorizontalDivider()
        LogShareRow("Share text file", "Plain log file · ${Formatter.formatShortFileSize(context, prepared.text.length())}",
          { Icon(Icons.Outlined.Description, null) }) { launchShare { shareFile(prepared.text, "text/plain") } }
        HorizontalDivider()
      } else if (error == null) Row(Modifier.padding(vertical = 20.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp); Text("Preparing logs…")
      }
      val value = text
      if (value != null && (prepared != null || error != null)) {
        val fits = value.length <= MAX_INLINE_LOG_CHARACTERS
        LogShareRow("Share as text", if (fits) "Paste into a message" else "Too large for a message · use text file",
          { Icon(Icons.Outlined.ChatBubbleOutline, null) }, enabled = fits) { launchShare { shareText(value) } }
      }
      error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    }
  }
}

@Composable private fun LogShareRow(title: String, subtitle: String, icon: @Composable () -> Unit,
  enabled: Boolean = true, action: () -> Unit) {
  Row(Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = action).padding(vertical = 18.dp),
    horizontalArrangement = Arrangement.spacedBy(18.dp), verticalAlignment = Alignment.CenterVertically) {
    icon()
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
      Text(title, color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
      Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
  }
}
