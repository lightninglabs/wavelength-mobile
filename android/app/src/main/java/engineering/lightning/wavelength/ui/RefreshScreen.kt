package engineering.lightning.wavelength.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AccessTime
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private data class RefreshQuote(val result: RefreshResult, val amountSat: Long)

@Composable internal fun RefreshScreen(
  session: WalletSession,
  network: WalletNetwork,
  modifier: Modifier,
  showsReceipt: Boolean,
) {
  val journal = remember(session, network) { refreshJournal(session.fundsDirectory(network)) }
  val wallet by session.state.collectAsState()
  var receipt by remember { mutableStateOf<RefreshReceipt?>(null) }
  var observation by remember { mutableStateOf<RefreshObservation?>(null) }
  var followsReceipt by remember { mutableStateOf(showsReceipt) }
  var preview by remember { mutableStateOf<RefreshQuote?>(null) }
  var funds by remember { mutableStateOf<List<WalletVTXO>?>(null) }
  var error by remember { mutableStateOf<String?>(null) }
  var starting by remember { mutableStateOf(false) }
  var revision by remember { mutableIntStateOf(0) }
  val scope = rememberCoroutineScope()

  LaunchedEffect(revision) {
    preview = null
    try {
      val saved = journal.read()
      receipt = saved
      if (saved != null) {
        do {
          val observed = session.inspect { it.observeRefresh(saved.outpoints) }
          observation = observed
          if (observed.complete || observed.retryAllowed) break
          followsReceipt = true
          if (funds == null) {
            funds = session.inspect { client ->
              client.recoveryInventory().vtxos.filter { it.outpoint in saved.outpoints }
            }
          }
          delay(5_000)
        } while (true)
      }
      session.inspect { client ->
        val available = client.recoveryInventory().vtxos.filter { it.status == "live" || it.status == "expired" }
        val observed = observation
        if (saved != null && followsReceipt && observed?.complete == true) {
          funds = available
        } else {
          val retry = if (saved != null && (followsReceipt || observed?.complete != true)) {
            observed?.retrySelection(saved)?.filter { outpoint -> available.any { it.outpoint == outpoint } }.orEmpty()
          } else null
          // An empty selection means refresh all. Never send it for a retry.
          val quote = when {
            retry == null -> client.refreshFunds(emptyList(), true)
            retry.isEmpty() -> null
            else -> client.refreshFunds(retry, true).also { result ->
              check(result.outpoints.all(retry::contains)) { "Refresh selection changed. Check again." }
            }
          }
          val selected = available.filter { it.outpoint in quote?.outpoints.orEmpty() }
          funds = selected
          preview = quote?.takeIf { it.outpoints.isNotEmpty() }?.let { RefreshQuote(it, selected.sumOf { it.amountSat }) }
        }
      }
    } catch (e: CancellationException) { throw e }
    catch (e: Exception) { error = e.message ?: "Couldn’t check refresh status." }
  }

  fun start(quote: RefreshQuote) {
    if (starting) return
    val saved = receipt
    starting = true
    error = null
    scope.launch {
      try {
        session.fundsAction(network) { client, requireOwner ->
          check(journal.read() == saved) { "Refresh changed. Check status." }
          val next = RefreshReceipt(quote.result.outpoints, quote.amountSat)
          requireOwner()
          journal.write(next)
          followsReceipt = true
          receipt = next
          observation = null
          preview = null
          try {
            val queued = client.refreshFunds(next.outpoints, false).outpoints
            if (queued.isNotEmpty() && queued != next.outpoints) {
              val queuedFunds = funds.orEmpty().filter { it.outpoint in queued }
              val amount = queuedFunds.sumOf { it.amountSat }
              val admitted = RefreshReceipt(queued, amount)
              journal.write(admitted)
              receipt = admitted
              funds = queuedFunds
            }
          } finally { revision++ }
        }
        session.refresh()
      } catch (e: CancellationException) { throw e }
      catch (e: Exception) { error = e.message ?: "Couldn’t start refresh." }
      finally { starting = false }
    }
  }

  val quote = preview
  val observed = observation
  val showingReceipt = receipt != null && (followsReceipt || observed?.complete != true)
  val complete = showingReceipt && observed?.complete == true
  val groups = refreshExpiryGroups(funds.orEmpty(), wallet.info?.blockHeight ?: 0)
  val footer: (@Composable ColumnScope.() -> Unit)? = if (quote == null) null else {
    {
      SettingsValue("Estimated fee", quote.result.feeEstimate?.totalFeeSat?.let(::sats) ?: "Unavailable")
      WalletButton("Start refresh", !starting) { start(quote) }
    }
  }
  FundPage(modifier, footer = footer) {
    val amount = when {
      complete -> observed?.confirmedSat ?: 0
      quote != null -> quote.amountSat
      showingReceipt -> receipt?.amountSat ?: 0
      else -> 0
    }
    if (amount > 0) Amount(amount)
    when {
      starting -> StatusLine("Starting refresh", true)
      complete -> Text("Refreshed")
      showingReceipt && observed?.retryAllowed == true -> {
        if (observed.confirmedSat > 0) Text("${sats(observed.confirmedSat)} refreshed")
        Text(if (quote == null) "Nothing to refresh right now" else "${sats(quote.amountSat)} ready to refresh")
      }
      showingReceipt -> StatusLine(if (observed == null) "Checking refresh status" else "Refresh in progress", error == null)
      quote != null -> Text("Refresh to keep these funds spendable in Wavelength.")
      error == null && funds == null -> StatusLine("Checking funds to refresh", true)
      error == null -> Text("Nothing to refresh right now")
    }
    quote?.result?.feeEstimate?.error?.takeIf(String::isNotEmpty)?.let { Text(it) }
    if (groups.isNotEmpty()) {
      Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(if (complete) "Wallet fund expiries" else "When your funds expire", style = MaterialTheme.typography.labelLarge)
        Surface(shape = MaterialTheme.shapes.medium) {
          Column {
            groups.forEachIndexed { index, group ->
              if (index > 0) HorizontalDivider()
              Row(Modifier.fillMaxWidth().padding(14.dp), horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.AccessTime, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Column {
                  Text(sats(group.amountSat), style = MaterialTheme.typography.bodyLarge)
                  Text(group.label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
              }
            }
          }
        }
      }
    }
    if (showingReceipt && observed != null) {
      SettingsValue("Confirmed", "${observed.confirmed} of ${receipt?.outpoints?.size ?: 0}")
      if (observed.remaining.isNotEmpty()) SettingsValue("Available for another refresh", sats(observed.remainingSat))
    }
    error?.let {
      Text(it, color = MaterialTheme.colorScheme.error)
      TextButton({ error = null; revision++ }, enabled = !starting) { Text("Check again") }
    }
  }
}
