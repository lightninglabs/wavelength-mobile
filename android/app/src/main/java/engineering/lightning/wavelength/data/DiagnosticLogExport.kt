package engineering.lightning.wavelength.data

import engineering.lightning.wavewalletdk.client.DiagnosticLog
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

internal const val MAX_INLINE_LOG_CHARACTERS = 100_000

internal fun exportLogText(records: List<DiagnosticLog>): String {
  val date = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("UTC") }
  return records.joinToString("\n") { "${date.format(Date(it.time))} ${it.level} ${it.source} ${it.message}" }
}

/** Only generated log attachments belong here. Never expose a wallet directory. */
internal data class DiagnosticLogFiles(val text: File, val zip: File) {
  companion object {
    fun prepare(text: String, network: String, root: File, now: Long = System.currentTimeMillis()): DiagnosticLogFiles {
      if (!root.isDirectory && !root.mkdirs()) throw IOException("Couldn’t create the log export folder")
      // Receivers can read after the chooser closes. Keep recent exports intact;
      // stale attachments are pruned on the next export, or by Android's cache cleanup.
      root.listFiles()?.filter { now - it.lastModified() > 86_400_000 }?.forEach { it.deleteRecursively() }
      val directory = File(root, UUID.randomUUID().toString())
      if (!directory.mkdir()) throw IOException("Couldn’t create the log export folder")
      try {
        val date = SimpleDateFormat("yyyy-MM-dd-HHmmss'Z'", Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("UTC") }
        val name = "wavelength-$network-${date.format(Date(now))}-logs"
        val file = File(directory, "$name.log")
        file.writer(Charsets.UTF_8).use { it.write(text) }
        val zip = File(directory, "$name.zip")
        ZipOutputStream(zip.outputStream().buffered()).use { archive ->
          archive.putNextEntry(ZipEntry(file.name))
          file.inputStream().use { it.copyTo(archive) }
          archive.closeEntry()
        }
        return DiagnosticLogFiles(file, zip)
      } catch (error: Exception) {
        directory.deleteRecursively()
        throw error
      }
    }
  }
}
