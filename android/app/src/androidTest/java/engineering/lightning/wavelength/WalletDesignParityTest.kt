package engineering.lightning.wavelength

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import engineering.lightning.wavewalletdk.client.*
import engineering.lightning.wavelength.data.PaymentUiState
import engineering.lightning.wavelength.data.WalletNetwork
import engineering.lightning.wavelength.ui.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

class WalletDesignParityTest {
  @get:Rule val compose = createComposeRule()
  private val funds = listOf(WalletVTXO("f".repeat(64) + ":0", 30_000), WalletVTXO("b".repeat(64) + ":1", 12_000))
  private val dark = mutableStateOf(true)

  @OptIn(ExperimentalMaterial3Api::class)
  @Composable private fun Page(title: String, body: @Composable ColumnScope.() -> Unit) {
    WalletTheme(dark.value) {
      Scaffold(topBar = { CenterAlignedTopAppBar(title = { Text(title) }) }) { padding ->
        FundPage(Modifier.padding(padding), body)
      }
    }
  }

  private fun capture(name: String) {
    if (InstrumentationRegistry.getArguments().getString("captureWalletScreens") != "1") return
    val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "wallet-design").apply { mkdirs() }
    File(directory, "$name.png").outputStream().use {
      compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
    }
  }

  @Test fun exitReviewKeepsFeeAndDestinationBeforeConfirmation() {
    compose.setContent {
      var external by remember { mutableStateOf(false) }
      Page("Exit") {
        ExitReview(funds, remember { TextFieldState() }, external, { external = it }, 240, false, null, {}, {})
      }
    }
    compose.onNodeWithText("My on-chain wallet").assertIsDisplayed()
    compose.onNodeWithText("240 sats").assertIsDisplayed()
    compose.onNodeWithText("Confirm exit").assertIsEnabled()
    capture("exit-dark")
    compose.runOnIdle { dark.value = false }
    capture("exit-light")
    compose.onNodeWithText("Use another address").performClick()
    compose.onNodeWithText("Confirm exit").assertIsNotEnabled()
    compose.onNodeWithContentDescription("To").performTextInput("tb1example")
    compose.onNodeWithText("Confirm exit").assertIsEnabled()
  }

  @Test fun availableBalanceReviewsTheDisplayedQuote() {
    val quote = PrepareSendResult(sendIntentId = "fixture", amountSat = 22000, expectedFeeSat = 250, feeKnown = true, rail = "onchain")
    var reviewed: PrepareSendResult? = null
    compose.setContent {
      Page("Send") {
        SendDraft(remember { TextFieldState("tb1fixture") }, remember { TextFieldState() }, WalletNetwork.SIGNET,
          remember { SendAmounts() }, { _, _ -> error("Expected on-chain destination") }, { quote }) { _, _, result -> reviewed = result }
      }
    }
    compose.onNodeWithContentDescription("Amount (sats)").performTextInput("3000")
    capture("send-dark")
    compose.runOnIdle { dark.value = false }
    capture("send-light")
    compose.onNodeWithText("Use available balance").performClick()
    compose.waitUntil(5_000) { compose.onAllNodesWithText("21,750").fetchSemanticsNodes().isNotEmpty() }
    compose.onNodeWithText("Review").performScrollTo().performClick()
    assertEquals(quote, reviewed)
    compose.onNodeWithText("Use available balance").performClick()
    compose.onNodeWithContentDescription("Amount (sats)").assertTextEquals("3000")
  }

  @Test fun refreshActionStaysVisibleWhenTheFundsListScrolls() {
    compose.setContent {
      WalletTheme(dark.value) {
        FundPage(Modifier, footer = { WalletButton("Start refresh") {} }) {
          repeat(20) { index -> Text("Expiry group $index", Modifier.height(60.dp)) }
        }
      }
    }
    compose.onNodeWithText("Start refresh").assertIsDisplayed()
    compose.onNodeWithText("Expiry group 19").performScrollTo().assertIsDisplayed()
    compose.onNodeWithText("Start refresh").assertIsDisplayed()
  }

  @Test fun onChainRequestShowsTheFullAddressWithCopyAndShare() {
    val address = "tb1q" + "x".repeat(58)
    compose.setContent {
      Page("Receive") { RequestCard(address, showAddress = true) }
    }
    compose.onNodeWithText(address).performScrollTo().assertIsDisplayed()
    compose.onNodeWithText("Copy").performScrollTo().assertIsDisplayed()
    compose.onNodeWithText("Share").assertIsDisplayed()
  }

  @OptIn(ExperimentalMaterial3Api::class)
  @Test fun receiveOpensFocusedAndKeepsCreateVisibleWhileEditingNote() {
    var request: Pair<Long, String>? = null
    val keyboardVisible = mutableStateOf(false)
    compose.setContent {
      WalletTheme(dark.value) {
        ModalBottomSheet(onDismissRequest = {}, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
          val hasKeyboard = WindowInsets.ime.getBottom(LocalDensity.current) > 0
          SideEffect { keyboardVisible.value = hasKeyboard }
          Column(Modifier.fillMaxWidth().fillMaxHeight(.95f).imePadding()) {
            ReceiveScreen(PaymentUiState(), emptyList(), { amount, note -> request = amount to note }, {})
          }
        }
      }
    }
    compose.onNodeWithContentDescription("Amount (sats)").assertIsFocused()
    compose.waitUntil(5_000) { keyboardVisible.value }
    compose.onNodeWithContentDescription("Amount (sats)").performTextInput("1700")
    compose.onNodeWithText("Create request").assertIsDisplayed()
    compose.onNodeWithText("Note").performScrollTo().performClick()
    compose.onNodeWithContentDescription("Note").performTextInput("Parity")
    compose.onNodeWithText("Create request").assertIsDisplayed().performClick()
    assertEquals(1700L to "Parity", request)
  }
}
