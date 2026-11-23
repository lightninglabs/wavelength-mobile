package engineering.lightning.wavelength

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import engineering.lightning.wavelength.data.WalletNetwork
import engineering.lightning.wavelength.ui.SendDraft
import engineering.lightning.wavelength.ui.scannedInvoice
import org.junit.Assert.*
import org.junit.Assume.assumeNotNull
import org.junit.Rule
import org.junit.Test

class SendInvoiceScanTest {
  @get:Rule val compose = createComposeRule()
  private val invoice = TextFieldState()
  private var reviews = 0

  @OptIn(ExperimentalMaterial3Api::class)
  private fun openDraft() {
    val note = TextFieldState()
    compose.setContent {
      ModalBottomSheet(onDismissRequest = {}, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column { SendDraft(invoice, note, WalletNetwork.SIGNET, false, { _, _ ->
          engineering.lightning.wavewalletdk.client.InvoiceDetails(amountSat = 125)
        }) { _, _, _ -> reviews++ } }
      }
    }
  }

  @Test fun scanAcceptsLightningForTheSelectedNetwork() {
    val expected = "LNTBS10N1EXAMPLE"
    assertEquals(expected, scannedInvoice(expected, WalletNetwork.SIGNET))
    assertEquals(expected, scannedInvoice("  LiGhTnInG://%4CNTBS10N1EXAMPLE\n", WalletNetwork.SIGNET))
    for (unsupported in listOf("", "https://example.com", "bitcoin:tb1qexample", "lntb10n1example")) {
      assertNull(scannedInvoice(unsupported, WalletNetwork.SIGNET))
    }
  }

  @Test fun typeAndPasteReplaceTheDraftBeforeExplicitReview() {
    openDraft()
    val field = compose.onNodeWithContentDescription("Invoice or Bitcoin address")
    field.performTextInput("lntbs1typed")
    field.assertTextEquals("lntbs1typed")
    compose.runOnIdle {
      InstrumentationRegistry.getInstrumentation().targetContext.getSystemService(ClipboardManager::class.java)
        .setPrimaryClip(ClipData.newPlainText("invoice", "lntbs1pasted"))
    }
    compose.onNodeWithText("Paste").performClick()
    field.assertTextEquals("lntbs1pasted")
    compose.runOnIdle { assertEquals(0, reviews) }
    compose.onNodeWithText("Review").performClick()
    compose.runOnIdle { assertEquals(1, reviews) }
  }

  // Point the emulator camera at a fixture and pass its normalized invoice as a runner argument.
  @Test fun cameraFillsDraftAndWaitsForReview() {
    val expected = InstrumentationRegistry.getArguments().getString("cameraInvoice")
    assumeNotNull(expected)
    openDraft()
    compose.onNodeWithText("Scan").performClick()
    compose.waitUntil(timeoutMillis = 30_000) { invoice.text.toString() == expected }
    compose.onNodeWithContentDescription("Invoice or Bitcoin address").assertTextEquals(expected!!)
    compose.onNodeWithText("Cancel").assertDoesNotExist()
    compose.onNodeWithText("Review").assertIsEnabled()
    compose.runOnIdle { assertEquals(0, reviews) }
  }
}
