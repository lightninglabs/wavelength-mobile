package engineering.lightning.wavelength.data

import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json

/** Atomically replace network-scoped operation evidence. Propagate unreadable records. */
internal class FundJournal<T>(private val path: File, private val serializer: KSerializer<T>, private val initial: T) {
  private val file = AtomicFile(path)
  private val json = Json { ignoreUnknownKeys = true }

  fun read(): T {
    val data = try { file.readFully() } catch (error: FileNotFoundException) {
      if (path.exists() || File(path.path + ".bak").exists()) throw error
      return initial
    }
    return json.decodeFromString(serializer, data.toString(Charsets.UTF_8))
  }

  fun write(value: T) {
    val bytes = json.encodeToString(serializer, value).toByteArray()
    val out = file.startWrite()
    try {
      out.write(bytes)
      out.fd.sync()
      file.finishWrite(out)
    } catch (error: Throwable) {
      file.failWrite(out)
      throw error
    }
  }
}
