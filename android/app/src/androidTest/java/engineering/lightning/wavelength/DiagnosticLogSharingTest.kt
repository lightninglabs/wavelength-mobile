package engineering.lightning.wavelength

import android.content.Intent
import android.net.Uri
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.*
import androidx.core.content.FileProvider
import androidx.test.platform.app.InstrumentationRegistry
import engineering.lightning.wavelength.data.DiagnosticLogFiles
import engineering.lightning.wavelength.ui.DiagnosticLogShare
import engineering.lightning.wavelength.ui.diagnosticLogFileIntent
import engineering.lightning.wavewalletdk.client.DiagnosticLog
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

class DiagnosticLogSharingTest {
  @get:Rule val compose = createComposeRule()

  @Test fun providerSharesOnlyLogAttachmentsWithTemporaryReadAccess() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val root = File(context.cacheDir, "diagnostic-exports")
    val files = DiagnosticLogFiles.prepare("Synthetic log 🌊", "signet", root)
    try {
      val intent = diagnosticLogFileIntent(context, files.text, "text/plain")
      @Suppress("DEPRECATION") val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)!!
      assertEquals("content", uri.scheme)
      assertEquals("text/plain", intent.type)
      assertEquals(uri, intent.clipData!!.getItemAt(0).uri)
      assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, intent.flags)
      assertEquals("Synthetic log 🌊", context.contentResolver.openInputStream(uri)!!.reader().use { it.readText() })
      val provider = context.packageManager.resolveContentProvider("${context.packageName}.diagnostic-exports", 0)!!
      assertFalse(provider.exported)
      assertTrue(provider.grantUriPermissions)
      assertThrows(IllegalArgumentException::class.java) {
        FileProvider.getUriForFile(context, "${context.packageName}.diagnostic-exports", File(context.filesDir, "not-a-log"))
      }
      assertEquals("application/zip", diagnosticLogFileIntent(context, files.zip, "application/zip").type)
    } finally { files.zip.parentFile!!.deleteRecursively() }
  }

  @Test fun allLogsOfferFilesAndExplainTheInlineSizeLimit() = withExportCleanup {
    val record = DiagnosticLog("fixture", 1_000, "INFO", "App", "Synthetic log 🌊".repeat(12_000))
    compose.setContent { MaterialTheme { DiagnosticLogShare(listOf(record), "signet", interval = false) } }
    compose.onNodeWithText("Share").performClick()
    try {
      compose.waitUntil(20_000) { compose.onAllNodesWithText("Share ZIP").fetchSemanticsNodes().isNotEmpty() }
    } catch (error: Throwable) {
      throw AssertionError(compose.onAllNodes(isRoot(), useUnmergedTree = true).printToString(maxDepth = 20), error)
    }
    compose.onNodeWithText("Share ZIP").assertIsDisplayed()
    compose.onNodeWithText("Share text file").assertIsDisplayed()
    compose.onNodeWithText("Share as text").assertIsNotEnabled()
    compose.onNodeWithText("Too large for a message · use text file").assertIsDisplayed()
  }

  @Test fun failedInlineIntervalStillOffersFiles() = withExportCleanup {
    val record = DiagnosticLog("fixture", 1_000, "INFO", "App", "Synthetic interval")
    compose.setContent {
      MaterialTheme {
        DiagnosticLogShare(listOf(record), "signet", interval = true,
          launchChooser = { throw IllegalStateException("Message sharing unavailable") })
      }
    }
    compose.onNodeWithText("Share").performClick()
    compose.waitUntil(20_000) { compose.onAllNodesWithText("Share ZIP").fetchSemanticsNodes().isNotEmpty() }
    compose.onNodeWithText("Share text file").assertIsDisplayed()
    compose.onNodeWithText("Couldn’t share logs.", substring = true).assertIsDisplayed()
  }

  private fun withExportCleanup(test: () -> Unit) {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val root = File(context.cacheDir, "diagnostic-exports")
    val existing = root.listFiles().orEmpty().toSet()
    try { test() }
    finally { root.listFiles().orEmpty().filterNot { it in existing }.forEach { it.deleteRecursively() } }
  }
}
