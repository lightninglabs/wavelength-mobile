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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import engineering.lightning.walletdk.client.WalletClient
import engineering.lightning.walletdk.client.WalletConfig
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// WalletDemoScreen drives the embedded wallet through the idiomatic WalletClient
// wrapper (suspend + Flow), rather than the raw gomobile bindings. It boots on
// signet, creates a wallet, watches the chain sync, and streams live activity.
//
// Endpoints default to Lightning Labs' public signet deployment (operator
// arkd-signet..., Esplora mempool.space/signet). Override here as needed.
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun WalletDemoScreen(dataDir: File, modifier: Modifier = Modifier) {
  val client = remember { WalletClient() }
  val scope = rememberCoroutineScope()

  var log by remember { mutableStateOf("Tap Start to boot the embedded wallet.\n") }
  var running by remember { mutableStateOf(false) }
  var busy by remember { mutableStateOf(false) }
  var walletReady by remember { mutableStateOf(false) }

  fun append(line: String) { log += line + "\n" }

  val config = remember(dataDir) {
    WalletConfig.signet(dataDir = "${dataDir.absolutePath}/walletdk")
  }

  // While running, poll readiness every 5s so the block height and server
  // connection are visible as the wallet syncs.
  LaunchedEffect(running) {
    while (running) {
      delay(5_000)
      runCatching { client.getInfo() }.onSuccess { info ->
        append(
          "sync: height=${info.blockHeight} state=${info.walletState} " +
            "operator=${if (info.serverConnected) "connected" else "…"}",
        )
      }
    }
  }

  // Once a wallet exists, stream live activity entries through the Flow.
  LaunchedEffect(walletReady) {
    if (!walletReady) return@LaunchedEffect
    runCatching {
      client.activity(includeExisting = true).collect { e ->
        append("activity: ${e.kind} ${e.amountSat}sat ${e.status} ${e.counterparty}")
      }
    }.onFailure { append("activity stream ended: ${it.message}") }
  }

  Column(
    modifier = modifier.fillMaxSize().padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(8.dp),
  ) {
    Text("walletdk signet demo", fontFamily = FontFamily.Monospace)

    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
      Button(
        enabled = !running && !busy,
        onClick = {
          busy = true
          append("Starting embedded daemon (signet)…")
          scope.launch {
            runCatching { client.start(config) }
              .onSuccess { running = true; append("gRPC serving. Create a wallet to sync.") }
              .onFailure { append("Start failed: ${it.message}") }
            busy = false
          }
        },
      ) { Text("Start") }

      Button(
        enabled = running && !walletReady,
        onClick = {
          append("Creating wallet…")
          scope.launch {
            runCatching { client.createWallet("damobile-demo-password".toByteArray()) }
              .onSuccess { res ->
                walletReady = true
                append("wallet created; identity=${res.identityPubKey.take(16)}…")
                append("seed words: ${res.mnemonic.size}; now syncing from Esplora.")
              }
              .onFailure { append("createWallet failed: ${it.message}") }
          }
        },
      ) { Text("Create Wallet") }

      Button(
        onClick = {
          scope.launch {
            runCatching { client.balance() }
              .onSuccess { append("balance: confirmed=${it.confirmedSat} pendingIn=${it.pendingInSat}") }
              .onFailure { append("balance failed: ${it.message}") }
          }
        },
      ) { Text("Balance") }

      Button(
        onClick = {
          scope.launch {
            runCatching { client.status() }
              .onSuccess { append("status: ready=${it.ready} unlocked=${it.unlocked} pending=${it.pendingCount}") }
              .onFailure { append("status failed: ${it.message}") }
          }
        },
      ) { Text("Status") }

      Button(
        onClick = {
          scope.launch {
            runCatching { client.stop() }
              .onSuccess { running = false; walletReady = false; append("Stopped.") }
              .onFailure { append("stop failed: ${it.message}") }
          }
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
