package engineering.lightning.wavelength.ui

import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import engineering.lightning.wavewalletdk.client.*
import engineering.lightning.wavelength.data.*
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

@Serializable internal data class SweepReceipt(val id: String, val destination: String, val net: Long,
  val feeRate: Long, val txid: String = "", val checks: Int = 0, val separate: Boolean = false,
  val confirmed: Boolean = false, val message: String = "")

internal fun SweepReceipt.checked(txs: List<OnchainTx>) = copy(checks = (checks + 1).coerceAtMost(2),
  confirmed = confirmed || (txid.isNotEmpty() && txs.any { it.txid == txid && it.status in setOf("confirmed", "complete") }))

internal suspend fun checkedSweepPreview(
  readExits: suspend () -> ExitSummary,
  preview: suspend () -> SweepPreview,
): SweepPreview {
  check(readExits().exits.isEmpty()) {
    "On-chain recovery needs funds for fees. Wait for recovery to finish before sending."
  }
  return preview()
}

@Composable internal fun SweepScreen(session: WalletSession, network: WalletNetwork, modifier: Modifier) {
  val journal = remember(network) { FundJournal(File(session.fundsDirectory(network), "sweeps.json"),
    ListSerializer(SweepReceipt.serializer()), emptyList()) }
  var receipts by remember { mutableStateOf(emptyList<SweepReceipt>()) }
  var loaded by remember { mutableStateOf(false) }
  var preview by remember { mutableStateOf<SweepPreview?>(null) }
  var target by remember { mutableStateOf("") }
  val destination = rememberTextFieldState()
  var busy by remember { mutableStateOf(false) }
  var error by remember { mutableStateOf<String?>(null) }
  var confirmSeparate by remember { mutableStateOf(false) }
  var revision by remember { mutableIntStateOf(0) }
  val scope = rememberCoroutineScope()
  fun save(next: List<SweepReceipt>) { journal.write(next); receipts = next }
  LaunchedEffect(revision) {
    try {
      session.inspect { client ->
        receipts = journal.read()
        loaded = true
        if (receipts.any { !it.confirmed }) {
          val txs = client.list(ListView.ONCHAIN, limit = 100).onchain?.txs ?: error("On-chain history unavailable")
          val next = receipts.map { it.checked(txs) }
          if (next != receipts) save(next)
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
  val active = receipts.lastOrNull { !it.separate }
  DiagnosticPage(modifier) {
    if (active != null) {
      Amount(active.net)
      Text(when { active.confirmed -> "Confirmed"; active.txid.isNotEmpty() -> "In progress"; else -> "Checking transfer" })
      CopyRow("Destination", active.destination)
      if (active.txid.isNotBlank()) CopyRow("Transaction", active.txid)
      if (active.message.isNotEmpty()) Text(active.message)
      TextButton({ revision++ }, enabled = !busy) { Text("Check status") }
      if (active.txid.isNotEmpty() || active.checks >= 2) TextButton({ confirmSeparate = true }, enabled = !busy) {
        Text("Review another transfer")
      }
    } else if (preview != null) {
      val quote = preview!!
      Amount(quote.netAmountSat)
      CopyRow("Destination", target)
      SettingsValue("Fee", sats(quote.estimatedFeeSat))
      SettingsValue("Fee rate", "${quote.feeRateSatPerVByte} sat/vB")
      if (quote.failureReason.isNotEmpty()) Text(quote.failureReason)
      WalletButton("Send on-chain funds", !busy && quote.canBroadcast && quote.feeRateSatPerVByte > 0) { run {
        session.fundsAction(network) { client, requireOwner ->
          val prior = journal.read()
          check(prior.none { !it.separate }) { "Check the existing transfer first." }
          val current = checkedSweepPreview(client::exitSummary) {
            client.sweepWallet(target, false, quote.feeRateSatPerVByte)
          }
          check(current.canBroadcast && current.netAmountSat == quote.netAmountSat && current.estimatedFeeSat == quote.estimatedFeeSat) {
            "Available funds or fees changed. Review the transfer again."
          }
          requireOwner()
          val pending = SweepReceipt(UUID.randomUUID().toString(), target, quote.netAmountSat, quote.feeRateSatPerVByte)
          save(prior + pending)
          preview = null
          val result = client.sweepWallet(target, true, pending.feeRate)
          if (result.txid.isEmpty() && result.totalInputSat == 0L) {
            save(prior)
            error(result.failureReason.ifEmpty { "No confirmed funds to send." })
          }
          save(prior + pending.copy(txid = result.txid, message = result.failureReason,
            net = if (result.txid.isEmpty()) pending.net else result.netAmountSat))
          revision++
        }
      } }
      TextButton({ preview = null }, enabled = !busy) { Text("Edit") }
    } else {
      WalletField("Destination address", destination)
      Text("Send all confirmed on-chain funds to this address.")
      WalletButton("Preview transfer", loaded && !busy && destination.text.isNotBlank()) {
        val address = destination.text.toString().trim()
        run {
          val quote = session.inspect { client ->
            checkedSweepPreview(client::exitSummary) { client.sweepWallet(address, false) }
          }
          target = address; preview = quote
        }
      }
    }
    receipts.filter { it.separate }.asReversed().forEach { old ->
      DetailSection("Previous transfer · ${sats(old.net)}") {
        CopyRow("Destination", old.destination)
        if (old.txid.isNotEmpty()) CopyRow("Transaction", old.txid) else Text("Broadcast unconfirmed")
      }
    }
    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
  }
  if (confirmSeparate && active != null) AlertDialog(onDismissRequest = { confirmSeparate = false },
    title = { Text("Review a separate transfer?") }, text = {
      Text(if (active.txid.isEmpty()) "The original transfer may have been broadcast. Its record will stay in Previous transfers."
        else "The original transaction stays in Previous transfers.")
    }, confirmButton = { TextButton({ confirmSeparate = false; run {
      val current = journal.read()
      check(current.lastOrNull()?.id == active.id)
      save(current.map { if (it.id == active.id) it.copy(separate = true) else it })
    } }) { Text("Review another") } }, dismissButton = { TextButton({ confirmSeparate = false }) { Text("Cancel") } })
}
