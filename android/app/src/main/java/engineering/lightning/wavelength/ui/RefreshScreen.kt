package engineering.lightning.wavelength.ui

import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.*
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.nullable

@Serializable internal data class RefreshReceipt(val outpoints: List<String>, val amountSat: Long)

/** An explicit retry may only preview outputs the wallet classifies as available. */
internal fun RefreshObservation.retrySelection(receipt: RefreshReceipt): List<String>? {
  if (complete) return emptyList()
  return remaining.takeIf { retryAllowed && it.isNotEmpty() && it.all(receipt.outpoints::contains) }
}

@Composable internal fun RefreshScreen(session: WalletSession, network: WalletNetwork, modifier: Modifier) {
  val journal = remember(network) { FundJournal(File(session.fundsDirectory(network), "refresh.json"), RefreshReceipt.serializer().nullable, null) }
  var receipt by remember { mutableStateOf<RefreshReceipt?>(null) }
  var observation by remember { mutableStateOf<RefreshObservation?>(null) }
  var preview by remember { mutableStateOf<RefreshResult?>(null) }
  var amount by remember { mutableLongStateOf(0) }
  var error by remember { mutableStateOf<String?>(null) }
  var busy by remember { mutableStateOf(false) }
  var revision by remember { mutableIntStateOf(0) }
  val scope = rememberCoroutineScope()
  LaunchedEffect(revision) {
    try {
      receipt = journal.read()
      val saved = receipt
      if (saved == null) {
        session.inspect { client ->
          val result = client.refreshFunds(emptyList(), true)
          val selected = result.outpoints.toSet()
          amount = client.recoveryInventory().vtxos.filter { it.outpoint in selected }.sumOf { it.amountSat }
          preview = result
        }
      } else {
        while (true) {
          observation = session.inspect { it.observeRefresh(saved.outpoints) }
          error = null
          if (observation?.retrySelection(saved) != null) break
          delay(5_000)
        }
      }
    } catch (e: CancellationException) { throw e }
    catch (e: Exception) { error = e.message }
  }
  fun run(action: suspend () -> Unit) {
    if (busy) return
    busy = true; error = null
    scope.launch {
      try { action() } catch (e: CancellationException) { throw e }
      catch (e: Exception) { error = e.message } finally { busy = false }
    }
  }
  DiagnosticPage(modifier) {
    val saved = receipt
    val quote = preview
    if (saved != null && quote == null) {
      val observed = observation
      if (saved.amountSat > 0) Amount(saved.amountSat)
      Text(when {
        observed == null -> "Checking status"
        observed.complete -> "Complete"
        observed.retryAllowed && observed.confirmed > 0 -> "Partially refreshed"
        observed.retryAllowed -> "Not completed"
        else -> "In progress"
      })
      observed?.let {
        SettingsValue("Confirmed", "${it.confirmed} of ${saved.outpoints.size}")
        SettingsValue("Refreshed", sats(it.confirmedSat))
        if (it.remaining.isNotEmpty()) SettingsValue("Available for another refresh", sats(it.remainingSat))
      }
      observed?.retrySelection(saved)?.let { available ->
        WalletButton(if (observed.complete) "New refresh" else "Review remaining", !busy) { run {
          session.inspect { client ->
            val result = client.refreshFunds(available, true)
            check(available.isEmpty() || result.outpoints.all(available::contains)) { "Refresh selection changed. Check status again." }
            amount = client.recoveryInventory().vtxos.filter { it.outpoint in result.outpoints }.sumOf { it.amountSat }
            preview = result
          }
        } }
      }
      DetailSection { saved.outpoints.forEach { CopyRow("Selected funds", it) } }
      TextButton({ revision++ }, enabled = !busy) { Text("Check status") }
    } else if (quote != null) {
      if (quote.outpoints.isEmpty()) Text("No funds to refresh") else {
        if (amount > 0) Amount(amount)
        SettingsValue("Fee estimate", quote.feeEstimate?.totalFeeSat?.let(::sats) ?: "Unavailable")
        quote.feeEstimate?.error?.takeIf(String::isNotEmpty)?.let { Text(it) }
        DetailSection { quote.outpoints.forEach { CopyRow("Selected funds", it) } }
        WalletButton("Confirm refresh", !busy) { run {
          session.fundsAction(network) { client, requireOwner ->
            check(journal.read() == saved) { "Refresh changed. Check status." }
            val next = RefreshReceipt(quote.outpoints, amount)
            requireOwner()
            journal.write(next)
            receipt = next; observation = null; preview = null
            try {
              val queued = client.refreshFunds(next.outpoints, false).outpoints
              if (queued.isNotEmpty() && queued != next.outpoints) {
                val admitted = next.copy(outpoints = queued)
                journal.write(admitted); receipt = admitted
              }
            } finally { revision++ }
          }
        } }
      }
    } else if (error == null) CircularProgressIndicator()
    error?.let { Text(it, color = MaterialTheme.colorScheme.error)
      TextButton({ error = null; revision++ }, enabled = !busy) { Text("Check again") }
    }
  }
}
