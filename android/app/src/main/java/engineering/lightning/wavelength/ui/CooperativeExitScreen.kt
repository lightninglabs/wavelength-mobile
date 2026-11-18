package engineering.lightning.wavelength.ui

import androidx.compose.foundation.layout.*
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
  var funds by remember { mutableStateOf(emptyList<WalletVTXO>()) }
  var selected by remember { mutableStateOf(emptySet<String>()) }
  var external by remember { mutableStateOf(false) }
  val address = rememberTextFieldState()
  var review by remember { mutableStateOf<List<WalletVTXO>?>(null) }
  var fee by remember { mutableStateOf<Long?>(null) }
  var busy by remember { mutableStateOf(false) }
  var error by remember { mutableStateOf<String?>(null) }
  var revision by remember { mutableIntStateOf(0) }
  val scope = rememberCoroutineScope()
  val selection = funds.filter { it.outpoint in selected }
  fun save(next: List<BatchExit>) { journal.write(next); records = next }
  LaunchedEffect(revision) {
    try {
      session.inspect { client ->
        records = journal.read()
        val activity = client.list(limit = 1000).activity?.entries ?: error("Activity unavailable")
        val next = records.map { it.reconcile(activity) }
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
  DiagnosticPage(modifier) {
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
      if (funds.isEmpty()) Text("No available funds")
      val reserved = records.flatMap { it.inputs }.filter { it.pending }.map { it.outpoint }.toSet()
      funds.forEach { fund ->
        Row {
          Checkbox(fund.outpoint in selected, { checked -> selected = if (checked) selected + fund.outpoint else selected - fund.outpoint },
            enabled = !busy && fund.outpoint !in reserved)
          CopyRow(sats(fund.amountSat), fund.outpoint)
        }
      }
      Row { Text("External Bitcoin address", Modifier.weight(1f)); Switch(external, { external = it }, enabled = !busy) }
      if (external) WalletField("Destination address", address)
      WalletButton("Review exit", !busy && selection.isNotEmpty() && (!external || target.isNotBlank())) { run {
        fee = session.inspect { client -> selection.sumOf { exitFee(it, client.estimateExitFee(it.outpoint)) } }
        review = selection
      } }
    } else {
      Amount(reviewed.sumOf { it.amountSat })
      CopyRow("Destination", target.ifEmpty { "My on-chain wallet" })
      SettingsValue("Estimated fee", fee?.let(::sats) ?: "Unavailable")
      Text("Each selected input creates a separate on-chain output. The round sets the final fee.")
      WalletButton("Confirm exit", !busy && fee != null) { run {
        session.fundsAction(network) { client, requireOwner ->
          val previous = journal.read()
          val existing = previous.flatMap { it.inputs }.filter { it.pending }.map { it.outpoint }
          check(reviewed.isNotEmpty() && reviewed.none { it.outpoint in existing }) { "Check the existing exit." }
          val baseline = client.list(limit = 1000).activity?.entries ?: error("Activity unavailable")
          requireOwner()
          val pending = BatchExit(reviewed.map { ExitInput(it.outpoint, it.amountSat) }, target,
            baseline.map { it.id }, Instant.now().epochSecond)
          save(previous + pending)
          review = null
          selected = emptySet()
          val result = try {
            pending.admitted(client.exitBatch(pending.inputs.map { it.outpoint }, target))
          } catch (e: CancellationException) { throw e }
          catch (e: Exception) {
            val message = e.message.orEmpty()
            val rejected = listOf("InvalidArgument", "FailedPrecondition", "Unimplemented").any {
              message.startsWith("exit batch (do not retry without reconciling admission): rpc error: code = $it desc = ")
            }
            pending.copy(error = message, inputs = if (rejected) pending.inputs.map { it.copy(state = "Not exited") } else pending.inputs)
          }
          save(previous + result)
        }
        revision++
      } }
      TextButton({ review = null }, enabled = !busy) { Text("Edit") }
    }
    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
  }
}
