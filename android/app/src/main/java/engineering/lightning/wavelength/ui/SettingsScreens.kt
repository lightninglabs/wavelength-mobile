package engineering.lightning.wavelength.ui

import android.app.KeyguardManager
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import engineering.lightning.wavelength.BuildConfig
import engineering.lightning.wavelength.data.*

internal enum class WalletScreen(val title: String) { HOME(""), SETTINGS("Settings"), CONNECTION("Connection"), SECURITY("Security"), CREDIT("Credit"), ACTIVITY("Payment"), DIAGNOSTICS("Diagnostics") }

@Composable internal fun SettingsScreen(session: WalletSession, state: WalletUiState, modifier: Modifier,
  navigate: (WalletScreen) -> Unit, diagnostics: Boolean = false) {
  var appearance by remember { mutableStateOf(false) }
  Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 12.dp)) {
    SettingsNavigation("Security", Icons.Outlined.Lock) { navigate(WalletScreen.SECURITY) }; HorizontalDivider()
    SettingsNavigation("Credit", Icons.Outlined.Toll) { navigate(WalletScreen.CREDIT) }; HorizontalDivider()
    if (diagnostics) { SettingsNavigation("Diagnostics", Icons.Outlined.MonitorHeart) { navigate(WalletScreen.DIAGNOSTICS) }; HorizontalDivider() }
    SettingsNavigation("Appearance", Icons.Outlined.Contrast, state.appearance.title) { appearance = true }; HorizontalDivider()
    SettingsNavigation("Connection", Icons.Outlined.Language) { navigate(WalletScreen.CONNECTION) }; HorizontalDivider()
    NetworkControl(session, state)
  }
  if (appearance) AlertDialog(onDismissRequest = { appearance = false }, title = { Text("Appearance") },
    text = { Column { WalletAppearance.entries.forEach { value ->
      Row(Modifier.fillMaxWidth().clickable { session.setAppearance(value); appearance = false }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(value == state.appearance, { session.setAppearance(value); appearance = false })
        Text(value.title, Modifier.padding(start = 8.dp))
      }
    } } }, confirmButton = { TextButton({ appearance = false }) { Text("Cancel") } })
}

@Composable internal fun SettingsNavigation(title: String, icon: ImageVector, value: String = "", enabled: Boolean = true, action: () -> Unit) {
  Row(Modifier.fillMaxWidth().heightIn(min = 62.dp).clickable(enabled = enabled, onClick = action).padding(vertical = 12.dp),
    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
    Icon(icon, null, Modifier.size(22.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    Text(title, Modifier.weight(1f))
    if (value.isNotEmpty()) Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Icon(Icons.Outlined.ChevronRight, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
  }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun NetworkControl(session: WalletSession, state: WalletUiState) {
  var shown by remember { mutableStateOf(false) }
  var mainnet by remember { mutableStateOf(false) }
  SettingsNavigation("Network", Icons.Outlined.Hub, state.network.title, session.canChangeWallet) { shown = true }
  if (shown) ModalBottomSheet(onDismissRequest = { shown = false }, containerColor = MaterialTheme.colorScheme.background) {
    Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp)) {
      Text("Network", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(bottom = 20.dp))
      WalletNetwork.entries.filter { BuildConfig.DEBUG || it != WalletNetwork.REGTEST }.forEach { network ->
        Row(Modifier.fillMaxWidth().heightIn(min = 62.dp).clickable(enabled = session.canChangeWallet) {
          if (network == WalletNetwork.MAINNET && network != state.network) mainnet = true
          else { shown = false; session.switchNetwork(network) }
        }, verticalAlignment = Alignment.CenterVertically) {
          Text(network.title, Modifier.weight(1f))
          if (network == state.network) Icon(Icons.Outlined.Check, "Selected", tint = MaterialTheme.colorScheme.primary)
        }
        HorizontalDivider()
      }
    }
  }
  if (mainnet) AlertDialog(onDismissRequest = { mainnet = false }, title = { Text("Use Mainnet?") },
    text = { Text("Mainnet uses real bitcoin.") }, dismissButton = { TextButton({ mainnet = false }) { Text("Cancel") } },
    confirmButton = { TextButton({ mainnet = false; shown = false; session.switchNetwork(WalletNetwork.MAINNET) }) { Text("Use Mainnet") } })
}

@Composable internal fun SecurityScreen(session: WalletSession, state: WalletUiState, modifier: Modifier,
  authenticate: (() -> Unit) -> Unit) {
  val context = LocalContext.current
  val available = context.getSystemService(KeyguardManager::class.java).isDeviceSecure
  Column(modifier.verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Device authentication")
        Text(if (available) "Face, fingerprint or device credential" else "Set a device screen lock to enable", style = MaterialTheme.typography.bodySmall,
          color = MaterialTheme.colorScheme.onSurfaceVariant)
      }
      Switch(state.authentication, { enabled -> authenticate { session.setAuthentication(enabled) } }, enabled = available)
    }
    HorizontalDivider()
    SettingsValue("Auto-lock", if (state.authentication) "Immediately" else "Off")
    Text("Your wallet stays encrypted.", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
  }
}

@Composable internal fun CreditScreen(session: WalletSession, state: WalletUiState, modifier: Modifier, back: () -> Unit) {
  val credit = rememberTextFieldState(state.settings.credit.use.toString())
  val topup = rememberTextFieldState(state.settings.credit.topup.toString())
  val use = credit.text.toString().toLongOrNull(); val add = topup.text.toString().toLongOrNull()
  Column(modifier.verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
    state.balance?.let { Amount(it.creditAvailableSat) } ?: CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
    Text("Provider-held", color = MaterialTheme.colorScheme.onSurfaceVariant)
    state.balance?.creditReservedSat?.takeIf { it > 0 }?.let { SettingsValue("Reserved", sats(it)) }
    WalletField("Credit use limit (sats)", credit, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
    WalletField("Top-up limit (sats)", topup, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
    WalletButton("Save", use != null && add != null && use >= 0 && add >= 0) {
      session.saveCredit(CreditLimits(use!!, add!!)); back()
    }
  }
}

@Composable internal fun ConnectionScreen(session: WalletSession, state: WalletUiState, modifier: Modifier = Modifier) {
  val operator = rememberTextFieldState(state.settings.endpoints.operator)
  val swap = rememberTextFieldState(state.settings.endpoints.swap)
  val esplora = rememberTextFieldState(state.settings.endpoints.esplora)
  Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
    SettingsValue("Wallet", when (state.info?.walletState) { engineering.lightning.wavewalletdk.client.WalletState.READY -> "Ready"; engineering.lightning.wavewalletdk.client.WalletState.LOCKED -> "Locked"; engineering.lightning.wavewalletdk.client.WalletState.NONE -> "Not created"; else -> "Connecting" })
    SettingsValue("Provider", if (state.info?.serverConnected == true) "Connected" else "Unavailable")
    state.info?.identityPubKey?.takeIf { it.isNotEmpty() }?.let { identity ->
      DetailSection("Client ID · ${identity.take(8)}…${identity.takeLast(8)}") { CopyRow("Client ID", identity) }
    }
    DetailSection("Endpoints") {
      Text("Leave blank to use defaults.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
      WalletField("Operator", operator, placeholder = state.network.operator.ifEmpty { "host:port" })
      WalletField("Swap service", swap, placeholder = state.network.swap.ifEmpty { "host:port" })
      WalletField("Esplora", esplora, placeholder = state.network.esplora.ifEmpty { "API URL" }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
      val value = EndpointOverrides(operator.text.toString(), swap.text.toString(), esplora.text.toString())
      val valid = runCatching { value.validated() }.getOrNull()
      WalletButton("Save connection", session.canChangeWallet && valid != null && valid != state.settings.endpoints) { session.saveConnection(value) }
    }
    SettingsValue("Version", state.info?.version.orEmpty())
    SettingsValue("Block height", state.info?.blockHeight?.toString() ?: "Unavailable")
  }
}

@Composable internal fun SettingsValue(label: String, value: String) {
  Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
    Text(label); Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant)
  }
}

/** Creation-only secrets never enter saved state, clipboard or a persistent file. */
@Composable internal fun CreationBackup(words: List<String>, done: () -> Unit) {
  SensitiveScreen()
  var revealed by remember { mutableStateOf(false) }
  var acknowledged by remember { mutableStateOf(false) }
  BackHandler {}
  Column(Modifier.fillMaxSize().systemBarsPadding().padding(24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
    Text("Recovery words", style = MaterialTheme.typography.headlineMedium)
    Text("Shown once. Write them down and keep them offline.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    Text("Recovery words alone may not recover off-chain funds.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    LazyVerticalGrid(GridCells.Fixed(2), Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(18.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
      itemsIndexed(words) { index, word ->
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
          Text((index + 1).toString(), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall)
          Text(if (revealed) word else "••••••", fontFamily = FontFamily.Monospace)
        }
      }
    }
    TextButton({ revealed = !revealed }) { Text(if (revealed) "Hide words" else "Reveal words") }
    Row(Modifier.fillMaxWidth().clickable { acknowledged = !acknowledged }, verticalAlignment = Alignment.CenterVertically) {
      Checkbox(acknowledged, { acknowledged = it }); Text("I saved my recovery words")
    }
    WalletButton("Done", acknowledged, onClick = done)
  }
}

@Composable internal fun SensitiveScreen() {
  val activity = LocalActivity.current
  DisposableEffect(activity) {
    activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    onDispose { if (BuildConfig.DEBUG) activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
  }
}
