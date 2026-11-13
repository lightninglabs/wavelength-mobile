package engineering.lightning.wavelength.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-bound encryption for the generated wallet password and recovery words.
 * The UI authentication gate is separate so native work can later run unattended.
 * No credential or recovery material is written to logs or Android backup.
 */
class WalletVault(context: Context) {
  private val directory = File(context.noBackupFilesDir, "wallet-secrets").apply { mkdirs() }
  private val key: SecretKey
    get() {
      val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
      return (store.getKey(ALIAS, null) as? SecretKey) ?: KeyGenerator.getInstance(
        KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore",
      ).apply {
        init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
          .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
          .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
          .setRandomizedEncryptionRequired(true).build())
      }.generateKey()
    }

  fun password(create: Boolean): ByteArray = read("signet-password") ?: run {
    check(create) { "Wallet credential unavailable. Restore using your recovery words." }
    ByteArray(32).also {
      SecureRandom().nextBytes(it)
      write("signet-password", it) // Durable before the daemon can create the wallet.
    }
  }

  fun saveWords(words: List<String>) = write("signet-backup", words.joinToString(" ").toByteArray())
  fun words(): List<String> = read("signet-backup")?.toString(Charsets.UTF_8)?.split(" ") ?: emptyList()

  private fun write(name: String, plaintext: ByteArray) {
    val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
    val bytes = byteArrayOf(cipher.iv.size.toByte()) + cipher.iv + cipher.doFinal(plaintext)
    val file = AtomicFile(File(directory, name))
    val out = file.startWrite()
    try { out.write(bytes); file.finishWrite(out) }
    catch (error: Throwable) { file.failWrite(out); throw error }
  }

  private fun read(name: String): ByteArray? {
    val file = AtomicFile(File(directory, name))
    if (!file.baseFile.exists() && !File(directory, "$name.bak").exists()) return null
    val bytes = file.readFully()
    require(bytes.isNotEmpty() && bytes[0].toInt() == 12 && bytes.size > 28) { "Wallet credential is unreadable" }
    return Cipher.getInstance("AES/GCM/NoPadding").run {
      init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
      doFinal(bytes.copyOfRange(13, bytes.size))
    }
  }

  private companion object { const val ALIAS = "wavelength.wallet.secrets.v1" }
}
