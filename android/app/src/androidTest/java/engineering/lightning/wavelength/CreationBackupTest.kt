package engineering.lightning.wavelength

import androidx.compose.material3.Surface
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import engineering.lightning.wavelength.ui.CreationBackup
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CreationBackupTest {
  private var creations = 0
  @get:Rule val compose = createComposeRule()

  private fun showBackup() {
    compose.setContent { Surface { CreationBackup(List(24) { "synthetic-$it" }) { creations++ } } }
  }

  @Test fun createRequiresRevealAndAcknowledgment() {
    showBackup()
    compose.onNodeWithText("Create wallet").assertIsNotEnabled()
    compose.onNodeWithText("Reveal words").performClick()
    compose.onNodeWithText("Create wallet").assertIsNotEnabled()
    compose.onNodeWithText("I saved my recovery words").performClick()
    compose.onNodeWithText("Create wallet").performClick()
    compose.runOnIdle { assertEquals(1, creations) }
  }
}
