package engineering.lightning.wavelength.data

/** Volatile, creation-only words. Callers serialize access with the session lifecycle. */
internal class WalletCreation(
  private val generate: suspend () -> List<String>,
  private val initialize: suspend (List<String>) -> Unit,
) {
  private var pending: List<String>? = null

  suspend fun prepare(): List<String> {
    check(pending == null) { "Backup is already pending" }
    val words = generate()
    check(words.size == 24) { "Expected 24 recovery words" }
    pending = words
    return words
  }

  suspend fun acknowledge() {
    val words = checkNotNull(pending) { "No backup to acknowledge" }
    // Consume before initialization: a lost startup response must not create again.
    pending = null
    initialize(words)
  }

  suspend fun restore(words: List<String>) {
    check(pending == null && words.isNotEmpty()) { "Recovery words are required" }
    initialize(words)
  }

  fun discard() { pending = null }
}
