package engineering.lightning.wavelength.data

import android.content.Context
import engineering.lightning.wavewalletdk.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

/** One process-owned daemon. Rotation and navigation never create another wallet. */
class WalletSession(context: Context) {
  val client = WalletClient()
  private val vault = WalletVault(context)
  private val directory = File(context.noBackupFilesDir, "wallets/signet")
  val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val lifecycle = Mutex()
  private val reads = Mutex()
  private val mutable = MutableStateFlow(WalletUiState())
  val state = mutable.asStateFlow()
  private var observations: Job? = null
  private var foreground = false
  val payments = PaymentOperations(scope, NativePaymentGateway(client),
    FilePaymentJournal(File(directory.apply { mkdirs() }, "pending-payment.json")),
    allowed = { foreground && mutable.value.phase == WalletPhase.OPEN }, onEntry = ::upsert)


  fun resume() {
    foreground = true
    scope.launch {
      lifecycle.withLock {
        try {
          if (!client.isRunning) {
            mutable.update { it.copy(phase = WalletPhase.OPENING, error = null) }
            client.start(WalletConfig.signet(directory.absolutePath).copy(hostDrivenIngress = true))
          }
          val info = client.getInfo()
          mutable.update { it.copy(info = info) }
          if (info.walletState == WalletState.NONE) {
            mutable.update { it.copy(phase = WalletPhase.SETUP) }
          } else if (mutable.value.phase != WalletPhase.OPEN) {
            mutable.update { it.copy(phase = WalletPhase.LOCKED) }
          }
          if (mutable.value.phase == WalletPhase.OPEN) startObservations()
        } catch (error: Exception) { fail(error) }
      }
    }
  }

  fun pause() {
    foreground = false
    observations?.cancel(); observations = null
    mutable.update { it.copy(phase = if (it.phase == WalletPhase.OPEN) WalletPhase.LOCKED else it.phase) }
    scope.launch { lifecycle.withLock { if (client.isRunning) runCatching { client.setHostForeground(false) } } }
  }

  fun open(create: Boolean = false, mnemonic: List<String> = emptyList()) {
    scope.launch {
      lifecycle.withLock {
        mutable.update { it.copy(phase = WalletPhase.OPENING, error = null) }
        try {
          val password = withContext(Dispatchers.IO) { vault.password(create) }
          try {
            if (create) {
              val result = client.createWallet(password, mnemonic)
              withContext(Dispatchers.IO) { vault.saveWords(result.mnemonic) }
            } else if (client.getInfo().walletState == WalletState.LOCKED) {
              client.unlockWallet(password)
            }
          } finally { password.fill(0) }
          if (!foreground) { mutable.update { it.copy(phase = WalletPhase.LOCKED) }; return@withLock }
          mutable.update { it.copy(phase = WalletPhase.OPEN) }
          // The wallet shell opens first. Network startup and snapshots follow.
          startObservations()
        } catch (error: Exception) { fail(error) }
      }
    }
  }

  private fun startObservations() {
    if (observations?.isActive == true) return
    observations = scope.launch {
      launch {
        while (isActive) {
          try {
            client.setHostForeground(true)
            client.activity(includeExisting = true).collect { entry ->
              mutable.update { it.copy(activity = (it.activity.filterNot { old -> old.id == entry.id } + entry)) }
            }
          } catch (error: CancellationException) { throw error }
          catch (_: Exception) { delay(3_000) }
        }
      }
      while (isActive) { refresh(); delay(5_000) }
    }
  }

  suspend fun refresh() = reads.withLock {
    supervisorScope {
      val balance = launch {
        try { val value = client.balance(); mutable.update { it.copy(balance = value) } }
        catch (error: CancellationException) { throw error }
        catch (_: Exception) { /* Retain the last observed balance. */ }
      }
      val activity = launch {
        try {
          val before = mutable.value.activity.associateBy { it.id }
          val result = client.list(limit = 1000).activity ?: error("Activity unavailable")
          mutable.update { current ->
            val merged = mergeActivitySnapshot(before, result.entries, current.activity)
            current.copy(activity = merged, activityLoaded = true, error = null)
          }
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { fail(error, fatal = false) }
      }
      launch { runCatching { client.getInfo() }.onSuccess { info -> mutable.update { it.copy(info = info) } } }
      balance.join(); activity.join()
      payments.reconcile(mutable.value.activity)
    }
  }

  fun dismissError() { mutable.update { it.copy(error = null) } }
  fun reportError(error: Throwable) = fail(error, fatal = false)
  fun upsert(entry: Entry) { mutable.update { it.copy(activity = it.activity.filterNot { old -> old.id == entry.id } + entry) } }
  suspend fun backupWords(): List<String> = withContext(Dispatchers.IO) { vault.words() }
  private fun fail(error: Throwable, fatal: Boolean = true) {
    if (error is CancellationException) throw error
    mutable.update { it.copy(phase = if (fatal) WalletPhase.ERROR else it.phase, error = error.message ?: "Wallet unavailable") }
  }
}

enum class WalletPhase { OPENING, SETUP, LOCKED, OPEN, ERROR }
data class WalletUiState(
  val phase: WalletPhase = WalletPhase.OPENING,
  val info: Info? = null,
  val balance: Balance? = null,
  val activity: List<Entry> = emptyList(),
  val activityLoaded: Boolean = false,
  val error: String? = null,
)
