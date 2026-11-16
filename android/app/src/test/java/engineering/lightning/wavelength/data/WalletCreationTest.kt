package engineering.lightning.wavelength.data

import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class WalletCreationTest {
  @get:Rule val temporary = TemporaryFolder()
  private val words = List(24) { "synthetic-$it" }

  @Test fun interruptionBeforeAcknowledgmentLeavesNoWallet() = runTest {
    val database = File(temporary.root, "wallet.db")
    var initialized = false
    fun session() = WalletCreation({ words }) {
      initialized = true
      database.writeText("wallet")
    }
    val original = session()
    original.prepare()
    assertFalse(initialized)
    assertFalse(database.exists())
    // A fresh process owns no pending phrase and must return to setup.
    val restarted = session()
    try { restarted.acknowledge(); fail("No backup survives process death") }
    catch (_: IllegalStateException) { }
    assertFalse(initialized)
    restarted.prepare()
    restarted.acknowledge()
    assertTrue(initialized)
    assertTrue(database.exists())
  }

  @Test fun startupFailureAfterPersistenceUsesAlreadyBackedUpWords() = runTest {
    val database = File(temporary.root, "wallet.db")
    var calls = 0
    var exactWords = false
    val creation = WalletCreation({ words }) { supplied ->
      calls++
      exactWords = supplied == words
      database.writeText("wallet")
      error("startup failed after persistence")
    }
    creation.prepare()
    assertEquals(0, calls)
    assertFalse(database.exists())
    try { creation.acknowledge(); fail("Expected startup failure") }
    catch (_: IllegalStateException) { }
    assertTrue(exactWords)
    assertTrue(database.exists())
    try { creation.acknowledge(); fail("Consumed acknowledgment cannot create again") }
    catch (_: IllegalStateException) { }
    assertEquals(1, calls)
  }

  @Test fun discardDropsPendingBackupAndRestoreUsesProvidedWordsDirectly() = runTest {
    var generations = 0
    var initialized = false
    val creation = WalletCreation({ generations++; words }) { supplied -> initialized = supplied == words }
    creation.prepare()
    creation.discard()
    try { creation.acknowledge(); fail("Discarded backup cannot create") }
    catch (_: IllegalStateException) { }
    assertFalse(initialized)
    creation.restore(words)
    assertEquals(1, generations)
    assertTrue(initialized)
  }
}
