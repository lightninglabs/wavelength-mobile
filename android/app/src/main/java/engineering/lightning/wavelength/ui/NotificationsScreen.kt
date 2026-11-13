package engineering.lightning.wavelength.ui

import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import engineering.lightning.wavelength.background.WalletFirebase
import engineering.lightning.wavelength.data.*

@Composable internal fun NotificationsScreen(session: WalletSession, state: WalletUiState, modifier: Modifier) {
  val context = LocalContext.current
  val owner = LocalLifecycleOwner.current
  val revision by session.notices.revision.collectAsStateWithLifecycle()
  val consent = remember(revision,state.network) { session.notices.consent(state.network) }
  var permission by remember { mutableStateOf(session.notices.allowedBySystem()) }
  var confirm by remember { mutableStateOf(false) }
  var amounts by remember { mutableStateOf(false) }
  DisposableEffect(owner) {
    val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) permission = session.notices.allowedBySystem() }
    owner.lifecycle.addObserver(observer)
    onDispose { owner.lifecycle.removeObserver(observer) }
  }
  val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
    permission = granted && session.notices.allowedBySystem()
    if (permission) session.configureNotifications(true)
  }
  fun enable() {
    if (session.notices.allowedBySystem()) session.configureNotifications(true)
    else if (Build.VERSION.SDK_INT >= 33) request.launch(android.Manifest.permission.POST_NOTIFICATIONS)
  }
  Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement = Arrangement.spacedBy(24.dp)) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Column(Modifier.weight(1f),verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Payment alerts")
        Text("New locally verified Lightning receipts",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
      }
      Switch(consent != null,{ enabled -> if (enabled) confirm = true else session.configureNotifications(false) },modifier = Modifier.semantics { contentDescription = "Payment alerts" }, enabled = !state.info?.identityPubKey.isNullOrBlank())
    }
    if (consent != null) {
      Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Show received amounts",Modifier.weight(1f))
        Switch(consent.amounts,{ enabled -> if (enabled) amounts = true else session.configureNotifications(true,false) },modifier = Modifier.semantics { contentDescription = "Show received amounts" })
      }
      Text("Applies to new invoices. No older activity is announced.",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (!permission) {
      Text("Alerts are disabled in Android settings.",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
      TextButton({ context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE,context.packageName)) }) { Text("Open Android settings") }
    }
    HorizontalDivider()
    SettingsValue("Background maintenance","Automatic")
    Text("Android chooses when to run. The wallet can stay locked. Round completion is not guaranteed.",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
    SettingsValue("Push delivery",if (WalletFirebase.configured) "Awaiting relay enrollment" else "Not configured for this build")
    Text("Scheduled checks work without Firebase. Push delivery needs publisher configuration and Android relay enrollment.",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
  }
  if (confirm) AlertDialog(onDismissRequest = { confirm = false },title = { Text("Enable payment alerts?") },
    text = { Text("New invoice receipts may show generic activity alerts while the app is locked. Amounts stay hidden unless you enable them separately.") },
    dismissButton = { TextButton({ confirm = false }) { Text("Cancel") } },confirmButton = { TextButton({ confirm = false; enable() }) { Text("Enable") } })
  if (amounts) AlertDialog(onDismissRequest = { amounts = false },title = { Text("Show received amounts?") },
    text = { Text("Amounts for new invoices can appear on the lock screen after local verification. Existing requests are not included.") },
    dismissButton = { TextButton({ amounts = false }) { Text("Cancel") } },confirmButton = { TextButton({ amounts = false; session.configureNotifications(true,true) }) { Text("Show amounts") } })
}
