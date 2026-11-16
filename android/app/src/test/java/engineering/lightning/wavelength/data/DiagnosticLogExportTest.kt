package engineering.lightning.wavelength.data

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.zip.ZipFile

class DiagnosticLogExportTest {
  @Test fun zipContainsOnlyTheExactUnicodeLogSnapshot() {
    val root = Files.createTempDirectory("log-export").toFile()
    try {
      val text = "2026-11-16T10:00:00.123Z INFO App Árvíztűrő 🌊\n".repeat(20_000)
      val export = DiagnosticLogFiles.prepare(text, "signet", root)
      assertEquals(text, export.text.readText(Charsets.UTF_8))
      ZipFile(export.zip).use { zip ->
        val entries = zip.entries().toList()
        assertEquals(1, entries.size)
        assertEquals(export.text.name, entries.single().name)
        assertEquals(text, zip.getInputStream(entries.single()).reader(Charsets.UTF_8).readText())
      }
      assertTrue(export.zip.length() < export.text.length())
      val next = DiagnosticLogFiles.prepare("next", "mainnet", root)
      assertNotEquals(export.zip, next.zip)
      assertEquals(text, export.text.readText(Charsets.UTF_8))
    } finally { root.deleteRecursively() }
  }

  @Test fun staleExportsAreRemovedButRecentAttachmentsSurvive() {
    val root = Files.createTempDirectory("log-export").toFile()
    try {
      val old = File(root, "old").apply { mkdir(); File(this, "old.log").writeText("old"); setLastModified(1) }
      val recent = File(root, "recent").apply { mkdir(); File(this, "recent.log").writeText("recent") }
      DiagnosticLogFiles.prepare("new", "testnet", root)
      assertFalse(old.exists())
      assertEquals("recent", File(recent, "recent.log").readText())
    } finally { root.deleteRecursively() }
  }

  @Test fun preparationReportsAnUnwritableDestination() {
    val root = Files.createTempFile("occupied", ".txt").toFile()
    try {
      root.writeText("occupied")
      assertThrows(java.io.IOException::class.java) { DiagnosticLogFiles.prepare("logs", "signet", root) }
      assertEquals("occupied", root.readText())
    } finally { root.delete() }
  }
}
