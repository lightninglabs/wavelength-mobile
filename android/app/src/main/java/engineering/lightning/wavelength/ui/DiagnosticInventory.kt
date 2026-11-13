package engineering.lightning.wavelength.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.input.rememberTextFieldState
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

@Composable internal fun DiagnosticVTXOs(session: WalletSession, modifier: Modifier, navigate: (DiagnosticRoute) -> Unit) {
  var history by remember { mutableStateOf(false) }
  var filter by remember { mutableStateOf("All") }
  val query = rememberTextFieldState()
  val result = diagnosticRead(session, DiagnosticView.VTXOS, history = history)
  val items = result.value["vtxos"].items.filter {
    ("${it["outpoint"].text} ${it["round_id"].text}".contains(query.text.toString(), ignoreCase = true)) &&
      when (filter) { "OOR" -> it["chain_depth"].number > 0; "Refresh due" -> refreshDue(it["expiry_info"]); else -> true }
  }.sortedBy { it["outpoint"].text }
  Column(modifier.fillMaxSize().padding(horizontal = 24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
    WalletField("Outpoint or round", query)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { listOf("All", "OOR", "Refresh due").forEach { name -> FilterChip(filter == name, { filter = name }, label = { Text(name) }) } }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
      Text("Include spent and forfeited", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
      Switch(history, { history = it })
    }
    Text("${items.size} ${if (items.size == 1) "VTXO" else "VTXOs"}", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelMedium)
    DiagnosticLoad(result)
    LazyColumn(Modifier.weight(1f)) {
      itemsIndexed(items) { _, item ->
        Row(Modifier.fillMaxWidth().clickable { navigate(DiagnosticRoute("vtxo", "VTXO", item, item["outpoint"].text)) }.padding(vertical = 20.dp),
          verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
          Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Text(shortId(item["outpoint"].text).ifEmpty { "Pending output" }, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelMedium)
            Text("${if (item["chain_depth"].number > 0) "OOR" else "Round"} · ${diagnosticLabel(item["status"].text)}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(expiryLabel(item["expiry_info"]), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (item["asset_ref"].text.isNotEmpty()) Text("Asset carrier", style = MaterialTheme.typography.labelSmall)
          }
          Text(if (item["amount_sat"] == JsonNull) "Unavailable" else sats(item["amount_sat"].number), style = MaterialTheme.typography.labelLarge)
          Icon(Icons.Outlined.ChevronRight, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        HorizontalDivider()
      }
      if (result.value != JsonNull && items.isEmpty()) item { Text("No matching VTXOs", Modifier.padding(vertical = 24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
  }
}

@Composable internal fun DiagnosticVTXO(session: WalletSession, route: DiagnosticRoute, modifier: Modifier, navigate: (DiagnosticRoute) -> Unit) {
  val result = if (route.target.isNotEmpty()) diagnosticRead(session, DiagnosticView.VTXO, outpoint = route.target) else DiagnosticResult()
  val anchors = if (route.target.isNotEmpty()) diagnosticRead(session, DiagnosticView.ANCHORS, outpoint = route.target) else DiagnosticResult()
  val item = if (result.value["found"].text == "true") result.value["vtxo"] else route.initial
  val expiry = if (result.value != JsonNull) result.value["expiry_info"] else item["expiry_info"]
  DiagnosticPage(modifier) {
    if (item["asset_ref"].text.isNotEmpty()) Text("Carrier value", color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (item["amount_sat"] != JsonNull) Amount(item["amount_sat"].number)
    Text("${if (item["chain_depth"].number > 0) "OOR" else "Round"} · ${diagnosticLabel(item["status"].text)}", color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (route.target.isNotEmpty()) CopyRow("VTXO outpoint", route.target)
    else Text("The output outpoint is assigned when its round confirms.", style = MaterialTheme.typography.bodySmall)
    Text("Expiry", style = MaterialTheme.typography.titleMedium)
    Text(expiryLabel(expiry), style = MaterialTheme.typography.titleLarge)
    ExpiryTimeline(expiry)
    if (expiry["batch_expiry"].number > 0) {
      SettingsValue("Expiry height", expiry["batch_expiry"].text)
      SettingsValue("Current height", expiry["current_height"].text)
      SettingsValue("Posture", diagnosticLabel(expiry["status"].text))
    }
    SettingsNavigation("Refresh timing", Icons.Outlined.Schedule, enabled = route.target.isNotEmpty()) { navigate(DiagnosticRoute("timing", "Refresh timing", target = route.target)) }
    HorizontalDivider()
    Text("Bitcoin anchoring outputs", style = MaterialTheme.typography.titleMedium)
    anchors.value.items.forEach { anchor ->
      CopyRow("Bitcoin outpoint", anchor["Outpoint"].text)
      SettingsValue("Output value", sats(anchor["AmountSat"].number))
      if (anchor["ConfirmationHeight"].number > 0) SettingsValue("Recorded confirmation", anchor["ConfirmationHeight"].text)
      DetailSection("Output script") { CopyRow("Script", anchor["PkScript"].text) }
      HorizontalDivider()
    }
    if (anchors.value.items.isEmpty()) Text(anchors.error ?: "Anchor output not available", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
    Text("Recorded ancestry; current spent status is not checked.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    item["commitment_txid"].text.takeIf { it.isNotEmpty() }?.let { CopyRow("Commitment transaction", it) }
    SettingsValue("OOR depth", "${item["chain_depth"].number} hops")
    item["round_id"].text.takeIf { it.isNotEmpty() }?.let { id ->
      SettingsNavigation("Round", Icons.Outlined.DonutLarge, shortId(id)) { navigate(DiagnosticRoute("round", "Round", buildJsonObject { put("round_id", id) })) }
    }
    DiagnosticRaw(if (result.value == JsonNull) item else result.value)
    DiagnosticShare(buildJsonObject { put("vtxo", if (result.value == JsonNull) item else result.value); put("anchors", anchors.value) }.pretty)
    result.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
  }
}

@Composable internal fun DiagnosticTiming(session: WalletSession, outpoint: String, modifier: Modifier) {
  val result = diagnosticRead(session, DiagnosticView.VTXO, outpoint)
  val info = diagnosticRead(session, DiagnosticView.INFO)
  val expiry = result.value["expiry_info"]
  val window = ExpiryWindow.from(expiry)
  DiagnosticPage(modifier) {
    Text(expiryLabel(expiry), style = MaterialTheme.typography.titleLarge)
    ExpiryTimeline(expiry)
    window?.let {
      SettingsValue("Refresh from", it.refresh.toString()); SettingsValue("Critical from", it.critical.toString()); SettingsValue("Expiry height", it.expiry.toString())
      if (info.value["server_info"] != JsonNull) {
        val free = info.value["server_info"]["free_refresh_window_blocks"].number
        SettingsValue("Operator free window", if (free == 0L) "Disabled" else "$free blocks")
        if (free > 0) SettingsValue("Free window opens", (it.expiry-free).toString())
      }
    }
    Text("Thresholds use the daemon’s expiry policy. Automatic refresh also needs an eligible zero-fee round and time to run. Android background scheduling is not enabled yet.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    DiagnosticLoad(result); DiagnosticLoad(info)
  }
}
