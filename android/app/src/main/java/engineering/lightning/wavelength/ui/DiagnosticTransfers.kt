package engineering.lightning.wavelength.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.DiagnosticView
import kotlinx.serialization.json.*

@Composable internal fun DiagnosticRounds(session: WalletSession, token: String, modifier: Modifier, navigate: (DiagnosticRoute) -> Unit) {
  val result = diagnosticRead(session, DiagnosticView.ROUNDS, pageToken = token)
  LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
    item { DiagnosticLoad(result) }
    itemsIndexed(result.value["rounds"].items) { _, item ->
      Column(Modifier.fillMaxWidth().clickable { navigate(DiagnosticRoute("round", "Round", item)) }.padding(vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(diagnosticLabel(item["state"].text), style = MaterialTheme.typography.titleMedium)
        Text(shortId(item["round_id"].text.ifEmpty { item["round_key"].text }), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (item["waiting_reason"].text.isNotEmpty()) Text(item["waiting_reason"].text, style = MaterialTheme.typography.bodySmall)
        if (item["batch_window"] != JsonNull) RoundTimeline(item["batch_window"])
      }
      HorizontalDivider()
    }
    if (result.value != JsonNull && result.value["rounds"].items.isEmpty()) item { Text("No rounds", color = MaterialTheme.colorScheme.onSurfaceVariant) }
    result.value["next_page_token"].text.takeIf { it.isNotEmpty() }?.let { next -> item {
      TextButton({ navigate(DiagnosticRoute("rounds", "Older rounds", token = next)) }) { Text("Older rounds") }
    } }
  }
}

@Composable internal fun DiagnosticRound(session: WalletSession, initial: JsonElement, modifier: Modifier, navigate: (DiagnosticRoute) -> Unit) {
  val id = initial["round_id"].text
  val result = diagnosticRead(session, if (id.isEmpty()) DiagnosticView.ROUNDS else DiagnosticView.ROUND, roundId = id)
  val round = if (result.value == JsonNull) initial else if (id.isNotEmpty()) result.value["round"]
    else result.value["rounds"].items.firstOrNull { it["round_key"].text == initial["round_key"].text } ?: JsonNull
  DiagnosticPage(modifier) {
    Text(diagnosticLabel(round["state"].text), style = MaterialTheme.typography.titleLarge)
    if (round == JsonNull && result.value != JsonNull) Text("This attempt is no longer in the active round list.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    round["waiting_reason"].text.takeIf { it.isNotEmpty() }?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    round["failure_reason"].text.takeIf { it.isNotEmpty() }?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    if (round["batch_window"] != JsonNull) {
      val window = round["batch_window"]
      Text("Schedule", style = MaterialTheme.typography.titleMedium); RoundTimeline(window)
      SettingsValue("Opens", diagnosticTime(window["registration_opens_unix"].number))
      SettingsValue("Cutoff", diagnosticTime(window["cutoff_unix"].number))
      SettingsValue("Planned join", diagnosticTime(window["planned_join_unix_ms"].number, true))
      Text("Local time. Planned join is not a background wakeup guarantee.", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
    }
    SettingsValue("Inputs", round["input_outpoints"].items.size.toString())
    round["input_outpoints"].items.forEach { CopyRow("Input", it.text) }
    listOf("round_id" to "Round ID", "round_key" to "Attempt", "commitment_txid" to "Commitment transaction").forEach { (key, label) ->
      round[key].text.takeIf { it.isNotEmpty() }?.let { CopyRow(label, it) }
    }
    if (round["commitment_height"].number > 0) SettingsValue("Recorded confirmation", round["commitment_height"].text)
    DiagnosticRaw(round)
    WalletButton("View related logs", secondary = true) { navigate(DiagnosticRoute("logs", "Logs", target = id.ifEmpty { round["round_key"].text })) }
    if (round != JsonNull) DiagnosticShare(round.pretty)
    DiagnosticLoad(result)
  }
}

@Composable internal fun DiagnosticTransfers(session: WalletSession, modifier: Modifier, navigate: (DiagnosticRoute) -> Unit) {
  var rail by remember { mutableStateOf("OOR") }
  var tokens by remember(rail) { mutableStateOf(emptyList<String>()) }
  var expanded by remember(rail, tokens) { mutableStateOf(false) }
  val result = diagnosticRead(session, when (rail) { "OOR" -> DiagnosticView.OOR; "Lightning" -> DiagnosticView.SWAPS; else -> DiagnosticView.CREDITS }, pageToken = tokens.lastOrNull().orEmpty())
  val items = result.value[when (rail) { "OOR" -> "sessions"; "Lightning" -> "swaps"; else -> "operations" }].items
  Column(modifier.fillMaxSize().padding(horizontal = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { listOf("OOR", "Lightning", "Credit").forEach { name -> FilterChip(rail == name, { rail = name }, label = { Text(name) }) } }
    if (rail == "Credit" && result.value != JsonNull) {
      SettingsValue("Available", sats(result.value["available_sat"].number)); SettingsValue("Reserved", sats(result.value["reserved_sat"].number))
    }
    DiagnosticLoad(result)
    if (result.value["diagnostic"]["package_evidence_unavailable"].text == "true") Text("Ark recovery evidence could not be loaded.")
    if (result.value["diagnostic"]["swap_evidence_unavailable"].text == "true") Text("Related Lightning swaps could not be loaded.")
    val (packages, transfers) = items.map { it to transferSummary(rail, it, result.value["ledger_entries"].items) }
      .partition { it.second.recoveryPackage }
    LazyColumn(Modifier.weight(1f)) {
      itemsIndexed(transfers) { _, (record, summary) -> TransferRow(record, summary, navigate) }
      if (packages.isNotEmpty()) item {
        TextButton({ expanded = !expanded }) { Text("Ark recovery packages (${packages.size})") }
      }
      if (expanded) itemsIndexed(packages) { _, (record, summary) -> TransferRow(record, summary, navigate) }
      if (result.value != JsonNull && items.isEmpty()) item { Text("No records", Modifier.padding(vertical = 24.dp)) }
      if (rail == "OOR") item {
        Row {
          if (tokens.isNotEmpty()) TextButton({ tokens = tokens.dropLast(1) }) { Text("Newer records") }
          result.value["next_page_token"].text.takeIf { it.isNotEmpty() }?.let { next ->
            TextButton({ tokens = tokens + next }) { Text("Older records") }
          }
        }
      }
    }
  }
}

@Composable private fun TransferRow(record: JsonElement, summary: TransferSummary, navigate: (DiagnosticRoute) -> Unit) {
  Column(Modifier.fillMaxWidth().clickable { navigate(DiagnosticRoute("record", summary.title, record)) }
    .padding(vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
    Text(summary.title, style = MaterialTheme.typography.titleMedium)
    summary.amount?.let { Text(it) }
    Text(summary.status, style = MaterialTheme.typography.bodySmall)
    if (summary.failure.isNotEmpty()) Text(summary.failure, color = MaterialTheme.colorScheme.error)
    val id = sequenceOf("session_id", "payment_hash", "operation_id").map { record[it].text }.firstOrNull { it.isNotEmpty() }
    id?.let { Text(shortId(it), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall) }
    if (summary.relatedSwap != JsonNull) TextButton({ navigate(DiagnosticRoute("record", "Lightning swap", summary.relatedSwap)) }) {
      Text("View Lightning swap")
    }
  }
  HorizontalDivider()
}
