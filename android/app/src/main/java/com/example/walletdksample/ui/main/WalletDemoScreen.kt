package com.example.walletdksample.ui.main

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import engineering.lightning.walletdk.mobile.Mobile
import java.io.File
import java.util.Base64
import kotlin.concurrent.thread
import kotlinx.coroutines.delay

// --- Signet environment ------------------------------------------------------
//
// Esplora drives chain sync; the Ark operator address is only needed for
// rounds / sends. Point ESPLORA_URL at your signet Esplora instance and
// OPERATOR_ADDRESS at your darepo operator mailbox. The defaults below use a
// public standard-signet Esplora so the wallet can sync out of the box.
//
// NOTE: darepod maps network "signet" to standard SigNetParams. If your env is
// a custom signet (e.g. mutinynet) the chain will not validate against these
// params; that needs a signet challenge wired into darepod first.
private const val ESPLORA_URL = "https://mempool.space/signet/api"
private const val OPERATOR_ADDRESS = "" // TODO: set your signet operator host:port
private const val DEMO_WALLET_PASSWORD = "damobile-demo-password"

// WalletDemoScreen boots the embedded wallet against signet, creates a wallet,
// and polls GetInfo so you can watch the lightweight (Esplora-backed) wallet
// sync the signet chain. It is dependency-light (raw JSON rendering) so the
// demo proves the FFI + sync path rather than UI polish.
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun WalletDemoScreen(dataDir: File, modifier: Modifier = Modifier) {
  var log by remember { mutableStateOf("Tap Start to boot the embedded wallet.\n") }
  var running by remember { mutableStateOf(false) }
  var starting by remember { mutableStateOf(false) }
  var walletReady by remember { mutableStateOf(false) }

  // Compose snapshot state is safe to write from any thread.
  fun append(line: String) {
    log += line + "\n"
  }

  val configJson = """
    {
      "data_dir": "${dataDir.absolutePath}/walletdk",
      "network": "signet",
      "server_address": "$OPERATOR_ADDRESS",
      "server_insecure": true,
      "wallet_type": "lwwallet",
      "wallet_esplora_url": "$ESPLORA_URL",
      "wallet_poll_interval_seconds": 30,
      "debug_level": "info"
    }
  """.trimIndent()

  // While the daemon is running, poll GetInfo every 5s so the log shows the
  // block height climbing to the signet tip as the wallet syncs.
  LaunchedEffect(running) {
    while (running) {
      delay(5_000)
      runCatching { String(Mobile.getInfo()) }
        .onSuccess { append("sync: $it") }
        .onFailure { /* transient during startup; ignore */ }
    }
  }

  Column(
    modifier = modifier.fillMaxSize().padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    Text("walletdk signet demo", fontFamily = FontFamily.Monospace)

    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
      Button(
        enabled = !running && !starting,
        onClick = {
          starting = true
          append("Starting embedded daemon (signet)…")
          thread(name = "walletdk-start") {
            runCatching { Mobile.start(configJson) }
              .onSuccess {
                running = true
                append("gRPC serving. Daemon up; create a wallet to sync.")
              }
              .onFailure { append("Start failed: ${it.message}") }
            starting = false
          }
        },
      ) { Text("Start") }

      Button(
        enabled = running && !walletReady,
        onClick = {
          append("Creating wallet…")
          val pw = Base64.getEncoder()
            .encodeToString(DEMO_WALLET_PASSWORD.toByteArray())
          val req = """{"WalletPassword":"$pw"}"""
          thread(name = "walletdk-create") {
            runCatching { String(Mobile.createWallet(req.toByteArray())) }
              .onSuccess {
                walletReady = true
                append("createWallet() -> $it")
                append("Wallet created; lwwallet is now syncing from Esplora.")
              }
              .onFailure { append("createWallet() failed: ${it.message}") }
          }
        },
      ) { Text("Create Wallet") }

      Button(
        onClick = {
          runCatching { String(Mobile.getInfo()) }
            .onSuccess { append("getInfo() -> $it") }
            .onFailure { append("getInfo() failed: ${it.message}") }
        },
      ) { Text("Get Info") }

      Button(
        onClick = {
          runCatching { String(Mobile.status()) }
            .onSuccess { append("status() -> $it") }
            .onFailure { append("status() failed: ${it.message}") }
        },
      ) { Text("Status") }

      Button(
        onClick = {
          runCatching { Mobile.stop() }
            .onSuccess {
              running = false
              walletReady = false
              append("Stopped.")
            }
            .onFailure { append("stop() failed: ${it.message}") }
        },
      ) { Text("Stop") }
    }

    Text(
      text = log,
      fontFamily = FontFamily.Monospace,
      modifier = Modifier.verticalScroll(rememberScrollState()),
    )
  }
}
