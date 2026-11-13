package engineering.lightning.wavelength.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Subject
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.DiagnosticView
import kotlinx.serialization.json.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun DiagnosticsApp(session: WalletSession, exit: () -> Unit) {
  var stack by remember { mutableStateOf(listOf(DiagnosticRoute("overview", "Diagnostics"))) }
  val route = stack.last()
  val navigate: (DiagnosticRoute) -> Unit = { stack = stack + it }
  val back: () -> Unit = { if (stack.size > 1) stack = stack.dropLast(1) else exit() }
  BackHandler(onBack = back)
  Scaffold(containerColor = MaterialTheme.colorScheme.background, topBar = {
    CenterAlignedTopAppBar(title = { Text(route.title) }, navigationIcon = { IconButton(back) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
      colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background))
  }) { padding -> key(route) {
    val page = Modifier.padding(padding)
    when (route.kind) {
      "overview" -> DiagnosticsOverview(session, page, navigate)
      "vtxos" -> DiagnosticVTXOs(session, page, navigate)
      "vtxo" -> DiagnosticVTXO(session, route, page, navigate)
      "timing" -> DiagnosticTiming(session, route.target, page)
      "rounds" -> DiagnosticRounds(session, route.token, page, navigate)
      "round" -> DiagnosticRound(session, route.initial, page, navigate)
      "transfers" -> DiagnosticTransfers(session, page, navigate)
      "logs" -> DiagnosticLogs(session, route.target, page, navigate,route.since,route.until)
      "background" -> DiagnosticBackground(session,page,navigate)
      "backgroundRun" -> DiagnosticBackgroundRun(session,route.target,page,navigate)
      "runs" -> DiagnosticHostRuns(session, page)
      "log" -> DiagnosticPage(page) {
        SettingsValue("Time", route.initial["time"].text)
        SettingsValue("Level", route.initial["level"].text)
        SettingsValue("Source", route.initial["source"].text)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) { Text("Message"); DiagnosticCopy(route.initial["message"].text) }
        androidx.compose.foundation.text.selection.SelectionContainer {
          Text(route.initial["message"].text, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
        }
        DiagnosticShare(route.initial.pretty)
      }
      "record" -> DiagnosticPage(page) { DiagnosticFields(route.initial); DiagnosticRaw(route.initial); DiagnosticShare(route.initial.pretty) }
      "info", "balance" -> {
        val result = diagnosticRead(session, if (route.kind == "info") DiagnosticView.INFO else DiagnosticView.BALANCE)
        DiagnosticPage(page) { DiagnosticLoad(result); DiagnosticFields(result.value); DiagnosticRaw(result.value); if (result.value != JsonNull) DiagnosticShare(result.value.pretty) }
      }
    }
  } }
}

@Composable private fun DiagnosticsOverview(session: WalletSession, modifier: Modifier, navigate: (DiagnosticRoute) -> Unit) {
  val state by session.state.collectAsStateWithLifecycle()
  val result = diagnosticRead(session, DiagnosticView.INFO)
  DiagnosticPage(modifier) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
      WaveMark(Modifier.size(36.dp))
      Surface(shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.surface) { Text(state.network.title, Modifier.padding(horizontal = 14.dp, vertical = 8.dp), style = MaterialTheme.typography.labelLarge) }
    }
    SettingsValue("Wallet", diagnosticLabel(result.value["wallet_state"].text).ifEmpty { "Loading" })
    SettingsValue("Chain tip", result.value["block_height"].text.ifEmpty { "…" })
    SettingsValue("Mailbox", if (result.value == JsonNull) "…" else if (result.value["server_connected"].text == "true") "Active" else "Paused")
    HorizontalDivider()
    Column {
      SettingsNavigation("VTXOs", Icons.Outlined.Layers) { navigate(DiagnosticRoute("vtxos", "VTXOs")) }; HorizontalDivider()
      SettingsNavigation("Rounds", Icons.Outlined.DonutLarge) { navigate(DiagnosticRoute("rounds", "Rounds")) }; HorizontalDivider()
      SettingsNavigation("Transfers & credit", Icons.Outlined.SwapVert) { navigate(DiagnosticRoute("transfers", "Transfers & credit")) }; HorizontalDivider()
      SettingsNavigation("Background", Icons.Outlined.Schedule) { navigate(DiagnosticRoute("background", "Background")) }; HorizontalDivider()
      SettingsNavigation("App runs", Icons.Outlined.Timeline) { navigate(DiagnosticRoute("runs", "App runs")) }; HorizontalDivider()
      SettingsNavigation("Logs", Icons.AutoMirrored.Outlined.Subject) { navigate(DiagnosticRoute("logs", "Logs")) }
    }
    HorizontalDivider()
    Column {
      SettingsNavigation("Runtime", Icons.Outlined.Memory) { navigate(DiagnosticRoute("info", "Runtime")) }
      SettingsNavigation("Balance breakdown", Icons.Outlined.BarChart) { navigate(DiagnosticRoute("balance", "Balance breakdown")) }
    }
    result.value["identity_pubkey"].text.takeIf { it.isNotEmpty() }?.let { CopyRow("Client ID", it) }
    DiagnosticLoad(result)
  }
}
