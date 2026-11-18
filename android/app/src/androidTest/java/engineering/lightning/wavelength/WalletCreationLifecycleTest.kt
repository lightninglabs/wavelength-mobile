package engineering.lightning.wavelength

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.WalletState
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Disposable native wallets only. No seed text is printed or attached to assertions. */
@RunWith(AndroidJUnit4::class)
class WalletCreationLifecycleTest {
  private class IsolatedContext(base: Context) : ContextWrapper(base) {
    private val id = UUID.randomUUID().toString()
    val root = File(base.cacheDir, "creation-$id").apply { mkdirs() }
    override fun getNoBackupFilesDir() = root
    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
      super.getSharedPreferences("creation-$id-$name", mode)
  }

  private suspend fun phase(session: WalletSession, expected: WalletPhase) = withTimeout(120_000) {
    session.state.first { it.phase == expected || it.phase == WalletPhase.ERROR }.also {
      assertTrue("Unexpected wallet phase: ${it.phase}", it.phase == expected)
    }
  }

  private suspend fun stop(session: WalletSession) {
    withContext(Dispatchers.Main) { session.pause(); session.scope.cancel() }
    session.client.stop()
  }

  private fun hasWallet(context: IsolatedContext) = context.root.walkTopDown().any {
    it.name == "wallet.db" || it.name == "wallet.sqlite.db"
  }

  private fun configure(context: Context, network: WalletNetwork) {
    WalletPreferences(context).apply {
      select(network)
      authentication(true)
      endpoints(network, EndpointOverrides(esplora = "http://127.0.0.1:9"))
    }
  }

  @Test fun abandonedBackupReturnsToSetupWithoutCredentialOrWallet() = runBlocking<Unit> {
    val context = IsolatedContext(ApplicationProvider.getApplicationContext())
    configure(context, WalletNetwork.TESTNET)
    var session = withContext(Dispatchers.Main) { WalletSession(context).also { it.resume() } }
    try {
      phase(session, WalletPhase.SETUP)
      withContext(Dispatchers.Main) { session.open(create = true) }
      val backup = phase(session, WalletPhase.BACKUP)
      assertEquals(24, backup.recoveryWords?.size)
      assertEquals(WalletState.NONE, session.client.getInfo().walletState)
      assertFalse(hasWallet(context))
      assertFalse(File(context.root, "wallet-secrets/testnet-password").exists())
      stop(session)
      session = withContext(Dispatchers.Main) { WalletSession(context).also { it.resume() } }
      phase(session, WalletPhase.SETUP)
      assertNull(session.state.value.recoveryWords)
      assertFalse(hasWallet(context))
      withContext(Dispatchers.Main) { session.switchNetwork(WalletNetwork.MAINNET) }
      phase(session, WalletPhase.SETUP)
      assertEquals(WalletNetwork.MAINNET, session.state.value.network)
      assertEquals(WalletState.NONE, session.client.getInfo().walletState)
    } finally { stop(session); context.root.deleteRecursively() }
  }

  @Test fun failedStartupCanPersistWalletOnlyAfterBackupAcknowledgment() = runBlocking<Unit> {
    val context = IsolatedContext(ApplicationProvider.getApplicationContext())
    configure(context, WalletNetwork.MAINNET)
    var session = withContext(Dispatchers.Main) { WalletSession(context).also { it.resume() } }
    try {
      phase(session, WalletPhase.SETUP)
      withContext(Dispatchers.Main) { session.open(create = true) }
      val backup = phase(session, WalletPhase.BACKUP)
      assertEquals(24, backup.recoveryWords?.size)
      assertFalse(hasWallet(context))
      withContext(Dispatchers.Main) { session.acknowledgeBackup() }
      phase(session, WalletPhase.ERROR)
      assertTrue(hasWallet(context))
      val credential = File(context.root, "wallet-secrets/mainnet-password")
      assertTrue(credential.exists())
      val originalCredential = credential.readBytes()
      assertNull(session.state.value.recoveryWords)
      stop(session)
      session = withContext(Dispatchers.Main) { WalletSession(context).also { it.resume() } }
      phase(session, WalletPhase.LOCKED)
      assertTrue(hasWallet(context))
      assertNull(session.state.value.recoveryWords)
      assertTrue(session.client.getInfo().walletState != WalletState.NONE)
      assertTrue("Existing credential must remain unchanged", originalCredential.contentEquals(credential.readBytes()))
      // Simulate a successful app authentication followed by native unlock failure.
      withContext(Dispatchers.Main) { session.open() }
      phase(session, WalletPhase.ERROR)
      val resumedPhase = withContext(Dispatchers.Main) {
        val next = async(start = CoroutineStart.UNDISPATCHED) {
          withTimeout(120_000) {
            session.state.first { it.phase == WalletPhase.LOCKED || it.phase == WalletPhase.OPENING }.phase
          }
        }
        session.pause(); session.resume()
        next.await()
      }
      assertEquals("A failed unlock consumes the authentication grant", WalletPhase.LOCKED, resumedPhase)
      // A new explicit credential result may still arrive before onStart.
      withContext(Dispatchers.Main) { session.pause(); session.open(); session.resume() }
      phase(session, WalletPhase.ERROR)
    } finally { stop(session); context.root.deleteRecursively() }
  }
}
