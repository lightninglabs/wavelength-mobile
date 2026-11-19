package engineering.lightning.wavelength.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.*
import java.io.File
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer

@Composable internal fun CooperativeExitScreen(session: WalletSession, network: WalletNetwork, modifier: Modifier) {
  val journal = remember(network) { FundJournal(File(session.fundsDirectory(network), "batch-exits.json"),
    ListSerializer(BatchExit.serializer()), emptyList()) }
  var records by remember { mutableStateOf(emptyList<BatchExit>()) }
  var funds by remember { mutableStateOf<List<WalletVTXO>?>(null) }
  var selected by remember { mutableStateOf(emptySet<String>()) }
  var external by remember { mutableStateOf(false) }
  val address = rememberTextFieldState()
  var review by remember { mutableStateOf<List<WalletVTXO>?>(null) }
  var fee by remember { mutableStateOf<Long?>(null) }
  var busy by remember { mutableStateOf(false) }
  var error by remember { mutableStateOf<String?>(null) }
  var revision by remember { mutableIntStateOf(0) }
  val scope = rememberCoroutineScope()
  val selection = funds.orEmpty().filter { it.outpoint in selected }
  fun save(next: List<BatchExit>) { journal.write(next); records = next }
  LaunchedEffect(revision) {
    try {
      session.inspect { client ->
        check(session.state.value.network == network) { "Reopen this wallet." }
        records = journal.read()
        val activity = client.list(limit = 1000).activity?.entries ?: error("Activity unavailable")
        val next = records.map { record ->
          val recovered = try {
            record.recover(client::resolveExitBatch)
          } catch (e: CancellationException) { throw e }
          catch (e: Exception) { error = e.message; record }
          recovered.reconcile(activity)
        }
        if (next != records) save(next)
        funds = client.list(ListView.VTXOS, limit = 1000).vtxos?.vtxos.orEmpty()
      }
    } catch (e: CancellationException) { throw e }
    catch (e: Exception) { error = e.message }
  }
  val target = if (external) address.text.toString().trim() else ""
  fun run(action: suspend () -> Unit) {
    if (busy) return
    busy = true
    error = null
    scope.launch {
      try { action() } catch (e: CancellationException) { throw e }
      catch (e: Exception) { error = e.message } finally { busy = false }
    }
  }
  BackHandler(review != null && !busy) { review = null }
  FundPage(modifier) {
    records.asReversed().forEach { record ->
      DetailSection("Exit · ${sats(record.inputs.sumOf { it.sats })}") {
        if (record.destination.isNotBlank()) CopyRow("Destination", record.destination)
        record.inputs.forEach { input ->
          CopyRow("${input.state} · ${sats(input.sats)}", input.outpoint)
          if (input.error.isNotBlank()) Text(input.error)
        }
        if (record.error.isNotEmpty()) Text(record.error)
      }
    }
    if (records.isNotEmpty() && review == null) TextButton({ revision++ }, enabled = !busy) { Text("Check status") }
    val reviewed = review
    if (reviewed == null) {
      Text("Choose funds", style = MaterialTheme.typography.titleLarge)
      if (funds == null && error == null) CircularProgressIndicator()
      if (funds?.isEmpty() == true) Text("No available funds", color = MaterialTheme.colorScheme.onSurfaceVariant)
      val reserved = records.flatMap { it.inputs }.filter { it.pending }.map { it.outpoint }.toSet()
      Column {
        funds.orEmpty().forEach { fund ->
          FundChoice(fund, fund.outpoint in selected, !busy && fund.outpoint !in reserved) { checked ->
            selected = if (checked) selected + fund.outpoint else selected - fund.outpoint
          }
        }
      }
      if (selection.isNotEmpty()) SettingsValue("Selected", sats(selection.sumOf { it.amountSat }))
      WalletButton("Continue", !busy && selection.isNotEmpty()) {
        val inputs = selection
        review = inputs
        fee = null
        run { fee = session.inspect { client -> inputs.sumOf { exitFee(it, client.estimateExitFee(it.outpoint)) } } }
      }
    } else {
      ExitReview(reviewed, address, external, { external = it }, fee, busy, error, onRetry = { run {
        fee = session.inspect { client -> reviewed.sumOf { exitFee(it, client.estimateExitFee(it.outpoint)) } }
      } }) { run {
        session.fundsAction(network) { client, requireOwner ->
          val previous = journal.read()
          val existing = previous.flatMap { it.inputs }.filter { it.pending }.map { it.outpoint }
          check(reviewed.isNotEmpty() && reviewed.none { it.outpoint in existing }) { "Check the existing exit." }
          val baseline = client.list(limit = 1000).activity?.entries ?: error("Activity unavailable")
          requireOwner()
          val pending = BatchExit(reviewed.map { ExitInput(it.outpoint, it.amountSat) }, target,
            baseline.map { it.id }, Instant.now().epochSecond, requestId = java.util.UUID.randomUUID().toString())
          save(previous + pending)
          review = null
          selected = emptySet()
          val result = try {
            pending.admitted(client.exitBatch(pending.inputs.map { it.outpoint }, target, pending.requestId))
          } catch (e: CancellationException) { throw e }
          catch (e: Exception) {
            pending.copy(error = e.message.orEmpty())
          }
          save(previous + result)
        }
        revision++
      } }
      TextButton({ review = null }, enabled = !busy) { Text("Change selection") }
    }
    if (review == null) error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
  }
}


@Composable internal fun ExitReview(funds: List<WalletVTXO>, address: TextFieldState, external: Boolean,
  onExternal: (Boolean) -> Unit, fee: Long?, busy: Boolean, error: String?, onRetry: () -> Unit, onConfirm: () -> Unit) {
  Amount(funds.sumOf { it.amountSat })
  if (external) WalletField("To", address, placeholder = "Bitcoin address")
  else SettingsValue("To", "My on-chain wallet")
  WalletToggle("Use another address", external, !busy, onExternal)
  if (busy && fee == null) StatusLine("Estimating fee", true)
  else SettingsValue("Estimated fee", fee?.let(::sats) ?: "Unavailable")
  if (error != null) {
    Text(error, color = MaterialTheme.colorScheme.error)
    if (fee == null) TextButton(onRetry, enabled = !busy) { Text("Retry") }
  }
  DetailSection {
    funds.forEach { CopyRow(sats(it.amountSat), it.outpoint) }
    Text("Each selected input creates a separate on-chain output. The round sets the final fee.",
      style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
  }
  WalletButton(if (busy && fee != null) "Submitting…" else "Confirm exit",
    !busy && fee != null && (!external || address.text.isNotBlank()), onClick = onConfirm)
}
