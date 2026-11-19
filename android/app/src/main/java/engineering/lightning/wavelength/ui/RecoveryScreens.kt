package engineering.lightning.wavelength.ui

import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.*
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable internal fun RecoveryMenu(session: WalletSession, modifier: Modifier, navigate: (WalletScreen) -> Unit) {
  DiagnosticPage(modifier) {
    val operations by session.payments.state.collectAsState()
    if (operations.unresolved.isNotEmpty()) DetailSection("Payment checks") {
      Text("These payments may still complete.")
      operations.unresolved.forEach { payment ->
        Amount(payment.recipientSat ?: payment.amountSat)
        CopyRow("Payment reference", payment.intentId)
        if (payment.paymentHash.isNotEmpty()) CopyRow("Payment hash", payment.paymentHash)
        if (payment.destination.isNotEmpty()) CopyRow("Destination", payment.destination)
      }
    }
    SettingsNavigation("Unilateral exit", Icons.Outlined.ArrowOutward) { navigate(WalletScreen.UNILATERAL) }
    SettingsNavigation("Send on-chain funds", Icons.Outlined.Send) { navigate(WalletScreen.SWEEP) }
    SettingsNavigation("Export recovery data", Icons.Outlined.Save) { navigate(WalletScreen.EXPORT) }
  }
}

@Composable internal fun UnilateralScreen(session: WalletSession, network: WalletNetwork, modifier: Modifier) {
  var funds by remember { mutableStateOf(emptyList<WalletVTXO>()) }
  var jobs by remember { mutableStateOf(emptyList<ExitSummaryEntry>()) }
  var selected by remember { mutableStateOf("") }
  var plan by remember { mutableStateOf<ExitPlanEntry?>(null) }
  var acknowledged by remember(selected) { mutableStateOf(false) }
  var statusFor by remember { mutableStateOf("") }
  var status by remember(statusFor) { mutableStateOf<ExitStatusResult?>(null) }
  var busy by remember { mutableStateOf(false) }
  var error by remember { mutableStateOf<String?>(null) }
  var revision by remember { mutableIntStateOf(0) }
  val scope = rememberCoroutineScope()
  LaunchedEffect(statusFor, revision) {
    try {
      if (statusFor.isEmpty()) {
        jobs = session.inspect { it.exitSummary().exits }
        funds = session.inspect { it.recoveryInventory().vtxos }
      } else while (true) {
        status = session.inspect { it.exitStatus(statusFor, detailed = true) }
        if (status?.status in setOf("completed", "failed")) break
        delay(5000)
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
    val item = plan
    if (statusFor.isNotEmpty()) {
      val result = status
      Text(if (result?.found == true) diagnosticLabel(result.status) else "Checking recovery status")
      result?.progress?.let { SettingsValue("Confirmed", "${it.confirmedTxs} of ${it.totalTxs} transactions") }
      result?.csv?.takeUnless { it.mature }?.let { SettingsValue("Waiting period", "${it.blocksRemaining} blocks") }
      result?.fees?.let {
        SettingsValue("Network cost so far", sats(it.spentSoFarSat))
        SettingsValue("Total estimated cost", sats(it.totalCostSat))
        SettingsValue(if (it.sweepFeeActual) "Final sweep fee" else "Sweep fee estimate", sats(it.sweepFeeSat))
        if (result.status == "completed") SettingsValue("Net recovered", sats(it.netRecoveredSat))
      }
      result?.lastError?.takeIf(String::isNotEmpty)?.let { Text(it) }
      CopyRow("Outpoint", statusFor)
      result?.sweepTxid?.takeIf(String::isNotEmpty)?.let { CopyRow("Sweep transaction", it) }
      TextButton({ revision++ }) { Text("Check status") }
    } else if (item != null) {
      CopyRow("Selected funds", item.outpoint)
      when {
        item.exitJobFound -> WalletButton("View existing recovery") { statusFor = item.outpoint }
        !item.canStart -> {
          Text(item.error.ifEmpty { diagnosticLabel(item.infeasibilityReason) })
          SettingsValue("Additional funding", sats(item.fundingShortfallSat))
          SettingsValue("Confirmed fee inputs", "${item.usableFeeUTXOCount} of ${item.requiredFeeUTXOCount}")
          SettingsValue("Each fee input", sats(item.recommendedUTXOAmountSat))
          SettingsValue("Confirmations required", item.requiredConfirmations.toString())
          if (item.fundingAddress.isNotBlank()) {
            Text("Fund each required input with a separate payment.")
            RequestCard(item.fundingAddress)
          }
          WalletButton("Check funding", !busy) { run {
            plan = session.inspect { client -> client.exitPlan(selected).plans.single { it.outpoint == selected } }
          } }
        }
        else -> {
          Text("Recovery sends these funds to your on-chain wallet. It includes a block waiting period and cannot be undone.")
          if (item.roundCommitment.isNotEmpty()) Text("These funds belong to an active round. Recovery may interrupt it.")
          Row { Text("I understand", Modifier.weight(1f)); Checkbox(acknowledged, { acknowledged = it }) }
          WalletButton("Start unilateral exit", acknowledged && !busy) { run {
            session.fundsAction(network) { client, requireOwner ->
              val current = client.exitPlan(item.outpoint).plans.single { it.outpoint == item.outpoint }
              requireOwner()
              statusFor = item.outpoint
              if (!current.exitJobFound) {
                check(current.canStart && current.roundCommitment == item.roundCommitment) { "Recovery plan changed. Review again." }
                client.exit(item.outpoint, forceUnrollAck = "I_KNOW_WHAT_I_AM_DOING")
              }
            }
          } }
        }
      }
      TextButton({ plan = null; acknowledged = false }, enabled = !busy) { Text("Choose funds") }
    } else {
      jobs.forEach { job -> WalletButton("View recovery · ${sats(job.vtxoAmountSat)}", secondary = true) { statusFor = job.outpoint } }
      if (funds.isEmpty()) Text("No available funds")
      funds.forEach { fund -> Row {
        RadioButton(selected == fund.outpoint, { selected = fund.outpoint }, enabled = !busy)
        CopyRow(sats(fund.amountSat), fund.outpoint)
      } }
      WalletButton("Check recovery plan", selected.isNotEmpty() && !busy) { run {
        plan = session.inspect { client -> client.exitPlan(selected).plans.single { it.outpoint == selected } }
      } }
    }
    error?.let { Text(it, color = MaterialTheme.colorScheme.error)
      TextButton({ revision++ }) { Text("Check again") }
    }
  }
}

@Composable internal fun RecoveryExportScreen(session: WalletSession, modifier: Modifier) {
  val context = LocalContext.current
  val scope = rememberCoroutineScope()
  var funds by remember { mutableStateOf(emptyList<WalletVTXO>()) }
  var selected by remember { mutableStateOf(emptySet<String>()) }
  var busy by remember { mutableStateOf(false) }
  var error by remember { mutableStateOf<String?>(null) }
  LaunchedEffect(session) {
    try { funds = session.inspect { it.recoveryInventory().vtxos } }
    catch (e: CancellationException) { throw e }
    catch (e: Exception) { error = e.message }
  }
  DiagnosticPage(modifier) {
    Text("Export the signed recovery package for the selected funds. Anyone you share it with can inspect the recovery transactions.")
    if (funds.isEmpty()) Text("No available funds") else TextButton({ selected =
      if (selected.size == funds.size) emptySet() else funds.map { it.outpoint }.toSet() }, enabled = !busy) {
      Text(if (selected.size == funds.size) "Deselect all" else "Select all")
    }
    funds.forEach { fund -> Row {
      Checkbox(fund.outpoint in selected, { on -> selected = if (on) selected + fund.outpoint else selected - fund.outpoint }, enabled = !busy)
      CopyRow(sats(fund.amountSat), fund.outpoint)
    } }
    WalletButton("Export package", selected.isNotEmpty() && !busy) {
      val selection = selected.sorted()
      busy = true
      scope.launch {
        try {
          val bytes = session.inspect { it.exportRecovery(selection) }
          val file = withContext(Dispatchers.IO) {
            val directory = File(context.cacheDir, "recovery-exports").apply { mkdirs() }
            directory.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 86_400_000 }?.forEach { it.delete() }
            File.createTempFile("wavelength-recovery-", ".json", directory).apply { writeBytes(bytes) }
          }
          context.startActivity(Intent.createChooser(diagnosticLogFileIntent(context, file, "application/json"), "Export recovery data"))
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { error = e.message }
        finally { busy = false }
      }
    }
    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
  }
}
