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
    if (round != JsonNull) DiagnosticShare(round.pretty)
    DiagnosticLoad(result)
  }
}

@Composable internal fun DiagnosticTransfers(session: WalletSession, modifier: Modifier, navigate: (DiagnosticRoute) -> Unit) {
  var rail by remember { mutableStateOf("OOR") }
  val result = diagnosticRead(session, when (rail) { "OOR" -> DiagnosticView.OOR; "Lightning" -> DiagnosticView.SWAPS; else -> DiagnosticView.CREDITS })
  val items = result.value[when (rail) { "OOR" -> "sessions"; "Lightning" -> "swaps"; else -> "operations" }].items
  Column(modifier.fillMaxSize().padding(horizontal = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { listOf("OOR", "Lightning", "Credit").forEach { name -> FilterChip(rail == name, { rail = name }, label = { Text(name) }) } }
    if (rail == "Credit" && result.value != JsonNull) {
      SettingsValue("Available", sats(result.value["available_sat"].number)); SettingsValue("Reserved", sats(result.value["reserved_sat"].number))
    }
    DiagnosticLoad(result)
    LazyColumn(Modifier.weight(1f)) {
      itemsIndexed(items) { _, item ->
        val direction = transferDirection(item)
        Column(Modifier.fillMaxWidth().clickable { navigate(DiagnosticRoute("record", if (rail == "Credit") "Credit operation" else "Transfer", item)) }.padding(vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
          Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(if (direction == "Incoming" || direction == "From credit") Icons.Outlined.SouthWest else if (direction == "Outgoing" || direction == "To credit") Icons.Outlined.ArrowOutward else Icons.Outlined.SwapHoriz,
              null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.primary)
            Text(direction, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
            Text(if (item["amount_sat"].number > 0) sats(item["amount_sat"].number) else "Amount unavailable", style = MaterialTheme.typography.labelLarge)
          }
          Text(diagnosticLabel(item[if (rail == "OOR") "phase" else "state"].text), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
          Text(shortId(item[when (rail) { "OOR" -> "session_id"; "Lightning" -> "payment_hash"; else -> "operation_id" }].text), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        HorizontalDivider()
      }
      if (result.value != JsonNull && items.isEmpty()) item { Text("No records", Modifier.padding(vertical = 24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
  }
}
