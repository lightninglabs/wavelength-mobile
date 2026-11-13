package engineering.lightning.wavelength.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.Crossfade
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.ArrowOutward
import androidx.compose.material.icons.outlined.SouthWest
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Check
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.Entry
import kotlinx.coroutines.launch
import kotlin.math.abs

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun WalletApp(session: WalletSession, authenticate: (() -> Unit) -> Unit) {
  val state by session.state.collectAsStateWithLifecycle()
  key(state.network) {
    var connection by remember { mutableStateOf(false) }
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
      if (state.phase == WalletPhase.OPEN && state.recoveryWords != null) {
        CreationBackup(state.recoveryWords!!, session::acknowledgeBackup)
      } else Crossfade(state.phase, label = "wallet phase") { phase ->
        when (phase) {
          WalletPhase.OPENING -> Column(Modifier.fillMaxSize(), Arrangement.Center, Alignment.CenterHorizontally) {
            WaveMark(Modifier.size(80.dp)); Spacer(Modifier.height(24.dp))
            CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
          }
          WalletPhase.SETUP -> Setup(session, state) { connection = true }
          WalletPhase.LOCKED -> Column(Modifier.fillMaxSize().padding(24.dp), Arrangement.Center, Alignment.CenterHorizontally) {
            WaveMark(Modifier.size(80.dp)); Spacer(Modifier.height(32.dp))
            Text("Wavelength", style = MaterialTheme.typography.headlineMedium)
            Text(state.network.title, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            WalletButton("Unlock") { authenticate { session.open() } }
            Spacer(Modifier.height(24.dp)); NetworkControl(session, state)
            TextButton({ connection = true }) { Text("Connection") }
          }
          WalletPhase.ERROR -> Column(Modifier.fillMaxSize().padding(24.dp), Arrangement.Center) {
            Text("Wallet unavailable", style = MaterialTheme.typography.headlineMedium)
            Text(state.error.orEmpty(), Modifier.padding(vertical = 24.dp))
            WalletButton("Try again") { session.retry() }
            NetworkControl(session, state); TextButton({ connection = true }) { Text("Connection") }
          }
          WalletPhase.OPEN -> WalletHome(session, state, authenticate)
        }
      }
      if (state.error != null && state.phase == WalletPhase.OPEN) AlertDialog(onDismissRequest = session::dismissError,
        title = { Text("Wallet") }, text = { Text(state.error.orEmpty()) }, confirmButton = { TextButton(session::dismissError) { Text("OK") } })
    }
    if (connection) ModalBottomSheet(onDismissRequest = { connection = false }, containerColor = MaterialTheme.colorScheme.background) {
      Text("Connection", Modifier.padding(horizontal = 24.dp, vertical = 16.dp), style = MaterialTheme.typography.titleLarge)
      ConnectionScreen(session, state)
    }
  }
}

@Composable private fun Setup(session: WalletSession, state: WalletUiState, connection: () -> Unit) {
  var restore by remember { mutableStateOf(false) }
  val words = remember { androidx.compose.foundation.text.input.TextFieldState() }
  if (restore) SensitiveScreen()
  Column(Modifier.fillMaxSize().systemBarsPadding().padding(24.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
    Spacer(Modifier.weight(1f)); WaveMark(Modifier.size(80.dp))
    Text("Wavelength", fontSize = 36.sp)
    Text(state.network.title, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Spacer(Modifier.weight(1f))
    if (restore) WalletField("Recovery words", words)
    WalletButton(if (restore) "Restore wallet" else "Create wallet", !restore || words.text.toString().trim().split(Regex("\\s+")).size == 24) {
      session.open(create = true, mnemonic = if (restore) words.text.toString().trim().split(Regex("\\s+")) else emptyList())
    }
    TextButton({ restore = !restore }) { Text(if (restore) "Create a new wallet" else "Restore wallet") }
    NetworkControl(session, state)
    TextButton(connection) { Text("Connection") }
  }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun WalletHome(session: WalletSession, state: WalletUiState, authenticate: (() -> Unit) -> Unit) {
  var stack by remember { mutableStateOf(listOf(WalletScreen.HOME)) }
  val screen = stack.last()
  val navigate: (WalletScreen) -> Unit = { stack = stack + it }
  val back: () -> Unit = { if (stack.size > 1) stack = stack.dropLast(1) }
  var selected by remember { mutableStateOf<String?>(null) }
  val scope = rememberCoroutineScope()
  BackHandler(stack.size > 1, back)
  Scaffold(containerColor = MaterialTheme.colorScheme.background, topBar = {
    CenterAlignedTopAppBar(title = {
      if (screen != WalletScreen.HOME) Text(screen.title) else Row(verticalAlignment = Alignment.CenterVertically) {
        WaveMark(); Spacer(Modifier.width(8.dp)); Text("wavelength", fontSize = 21.sp, fontWeight = FontWeight.Medium)
      }
    }, navigationIcon = { if (stack.size > 1) IconButton(back) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
      actions = { if (screen == WalletScreen.HOME) IconButton({ navigate(WalletScreen.SETTINGS) }) { Icon(Icons.Outlined.Settings, "Settings") } },
      colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background))
  }) { padding ->
    val page = Modifier.padding(padding)
    when (screen) {
      WalletScreen.SETTINGS -> { SettingsScreen(session, state, page, navigate); return@Scaffold }
      WalletScreen.SECURITY -> { SecurityScreen(session, state, page, authenticate); return@Scaffold }
      WalletScreen.CREDIT -> { CreditScreen(session, state, page, back); return@Scaffold }
      WalletScreen.CONNECTION -> { ConnectionScreen(session, state, page); return@Scaffold }
      WalletScreen.ACTIVITY -> {
        state.activity.firstOrNull { it.id == selected }?.let { ActivityDetails(it, page, state.activity) }
        return@Scaffold
      }
      else -> Unit
    }
    LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(24.dp),
      verticalArrangement = Arrangement.spacedBy(16.dp)) {
      item {
        Text("Balance", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(10.dp))
        val balance = state.balance
        if (balance == null) CircularProgressIndicator(Modifier.padding(vertical = 20.dp).size(24.dp), strokeWidth = 2.dp)
        else {
          Amount(balance.confirmedSat + balance.pendingInSat + balance.pendingOutSat)
          if (balance.pendingInSat + balance.pendingOutSat > 0) Text("${sats(balance.pendingInSat + balance.pendingOutSat)} pending",
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(Modifier.height(24.dp))
      }
      item { PaymentActions(session, state) }
      state.balance?.takeIf { it.creditAvailableSat > 0 }?.let { balance ->
        item {
          HorizontalDivider(); Spacer(Modifier.height(16.dp))
          Row(Modifier.fillMaxWidth().clickable { navigate(WalletScreen.CREDIT) }.heightIn(min = 44.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Credit"); Text(sats(balance.creditAvailableSat))
          }
          Text("Provider-held", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
          Spacer(Modifier.height(16.dp)); HorizontalDivider()
        }
      }
      item {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
          Text("Activity", fontSize = 24.sp, fontWeight = FontWeight.Medium)
          TextButton({ scope.launch { session.refresh() } }) { Text("Refresh") }
        }
      }
      val entries = visibleActivity(state.activity)
      if (!state.activityLoaded && entries.isEmpty()) item { CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp) }
      else if (entries.isEmpty()) item { Text("No activity", color = MaterialTheme.colorScheme.onSurfaceVariant) }
      items(entries, key = { it.id }) { item ->
        ActivityRow(item) { selected = item.id; navigate(WalletScreen.ACTIVITY) }
        HorizontalDivider()
      }
    }
  }
}

@Composable private fun ActivityRow(entry: Entry, onClick: () -> Unit) {
  Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
    Icon(if (entry.incoming) Icons.Outlined.SouthWest else Icons.Outlined.ArrowOutward, null, Modifier.size(24.dp))
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
      Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(entry.title, Modifier.weight(1f), maxLines = 1)
        val awaiting = entry.awaitingPayment || (entry.kind == "receive" && entry.failureCode == "expired")
        val prefix = if (awaiting || (entry.incoming && entry.status == "pending")) "" else if (entry.incoming) "+" else "−"
        Text(prefix + sats(abs(entry.amountSat)), color = if (awaiting) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
      }
      Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(entry.statusLabel, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
        Text(activityTime(entry.createdAt), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
      }
    }
  }
}

@Composable fun ActivityDetails(entry: Entry, modifier: Modifier = Modifier, entries: List<Entry> = emptyList()) {
  Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
    Amount(abs(entry.amountSat)); Text(entry.statusLabel)
    if (entry.note.isNotEmpty()) Text(entry.note)
    Text(activityTime(entry.createdAt), color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (entry.feeSat > 0) CopyRow("Fee", sats(entry.feeSat))
    PendingRequest(entry)
    DetailSection {
      entries.filter { it.creditTopup && entry.kind == "send" && !entry.creditTopup &&
        entry.paymentHash.isNotEmpty() && it.paymentHash == entry.paymentHash }.forEach { topup ->
        DetailSection("Credit top-up · ${sats(abs(topup.amountSat))}") {
          Text(topup.statusLabel, color = MaterialTheme.colorScheme.onSurfaceVariant)
          CopyRow("Reference", topup.id)
          topup.progress?.vtxoOutpoint?.takeIf { it.isNotEmpty() }?.let { CopyRow("Outpoint", it) }
        }
      }
      CopyRow("Reference", entry.id)
      entry.progress?.paymentHash?.takeIf { it.isNotEmpty() }?.let { CopyRow("Payment hash", it) }
      entry.request?.lightningInvoice?.takeIf { it.isNotEmpty() }?.let { CopyRow("Invoice", it) }
      entry.request?.onchainAddress?.takeIf { it.isNotEmpty() }?.let { CopyRow("On-chain", it) }
      if (entry.failureReason.isNotEmpty()) CopyRow("Status details", entry.failureReason)
    }
  }
}

@Composable fun CopyRow(label: String, value: String) {
  val clipboard = LocalClipboardManager.current
  var copied by remember(value) { mutableStateOf(false) }
  LaunchedEffect(copied) { if (copied) { kotlinx.coroutines.delay(1400); copied = false } }
  Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
      Text(label, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
      SelectionContainer { Text(value, style = MaterialTheme.typography.bodyMedium,
        maxLines = 3, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis) }
    }
    IconButton({ clipboard.setText(AnnotatedString(value)); copied = true }) {
      Icon(if (copied) Icons.Outlined.Check else Icons.Outlined.ContentCopy,
        if (copied) "Copied" else "Copy $label", Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
  }
}
