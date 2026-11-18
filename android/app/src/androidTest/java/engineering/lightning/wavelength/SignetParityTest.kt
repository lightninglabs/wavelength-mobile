package engineering.lightning.wavelength

import androidx.test.platform.app.InstrumentationRegistry
import engineering.lightning.wavewalletdk.client.*
import java.io.File
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in live test in an isolated directory on a disposable Signet emulator. */
class SignetParityTest {
  @Test fun receiveIdentitySurvivesDaemonRestart() = runBlocking<Unit> {
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    assumeTrue(InstrumentationRegistry.getArguments().getString("liveSignet") == "1")
    val client = WalletClient()
    check(!client.isRunning) { "A running wallet owns this process." }
    val root = File(instrumentation.targetContext.cacheDir, "signet-parity-${UUID.randomUUID()}")
    val config = WalletConfig.signet(root.absolutePath)
    val password = UUID.randomUUID().toString().toByteArray()
    val id = UUID.randomUUID().toString()
    try {
      client.start(config)
      client.createWallet(password, client.generateSeed().mnemonic)
      withTimeout(120_000) { while (!client.getInfo().serverConnected) delay(1000) }
      assertTrue(client.recoveryInventory().vtxos.isEmpty())
      assertTrue(client.exitSummary().exits.isEmpty())
      val address = client.newDepositAddress().address
      assertTrue(address.startsWith("tb1"))
      assertNull(client.lookupReceive(id))
      val created = client.receiveLightning(5000, "Disposable Android acceptance", id)
      assertEquals(5000L, client.decodeInvoice(created.invoice, "signet").amountSat)
      client.stop()
      client.start(config)
      if (client.getInfo().walletState == WalletState.LOCKED) client.unlockWallet(password)
      withTimeout(120_000) { while (!client.getInfo().serverConnected) delay(1000) }
      val recovered = client.lookupReceive(id)
      assertTrue("Recovered the original invoice", recovered?.invoice == created.invoice)
      assertEquals(created.entry.id, recovered?.entry?.id)
      assertEquals(created.receiptReference, recovered?.receiptReference)
      assertNull(client.lookupReceive(UUID.randomUUID().toString()))
    } finally {
      password.fill(0)
      client.stop()
      root.deleteRecursively()
    }
  }
}
