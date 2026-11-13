package engineering.lightning.wavelength

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material3.Surface
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import engineering.lightning.wavelength.ui.WalletField
import engineering.lightning.wavelength.ui.WalletTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WalletFieldTest {
  @get:Rule val compose = createComposeRule()

  @Test fun completeInvoiceSurvivesInputAndThemeRecomposition() {
    val field = TextFieldState()
    val dark = mutableStateOf(false)
    val invoice = "lntbs" + "0123456789abcdefghijklmnopqrstuvwxyz".repeat(16)
    compose.setContent { WalletTheme(dark.value) { Surface { WalletField("Lightning invoice", field) } } }
    compose.onNode(hasSetTextAction()).performTextInput(invoice)
    compose.onNode(hasSetTextAction()).assertTextEquals(invoice)
    compose.runOnIdle { dark.value = true }
    compose.onNode(hasSetTextAction()).assertTextEquals(invoice)
    compose.runOnIdle { field.edit { replace(0, length, "lntbs1replacement") } }
    compose.onNode(hasSetTextAction()).assertTextEquals("lntbs1replacement")
  }
}
