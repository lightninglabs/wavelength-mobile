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

/** One daemon with serialized ownership when moving between isolated wallets. */
class WalletSession(context: Context) {
  val client = WalletClient()
  val diagnostics = DiagnosticRuns()
  private val root = context.noBackupFilesDir
  private val vault = WalletVault(context)
  private val preferences = WalletPreferences(context)
  val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val lifecycle = Mutex()
  private val reads = Mutex()
  private val mutable = MutableStateFlow(WalletUiState(network = preferences.selectedNetwork,
    settings = preferences.network(preferences.selectedNetwork), appearance = preferences.appearance,
    authentication = preferences.authentication, captureLevel = preferences.captureLevel))
  val state = mutable.asStateFlow()
  private var observations: Job? = null
  private var foreground = false
  private var generation = 0L
  private var pendingUnlock: WalletNetwork? = null
  var payments = paymentOperations(mutable.value.network, generation)
    private set
  val canChangeWallet: Boolean get() = state.value.phase != WalletPhase.OPENING && state.value.recoveryWords == null &&
    !payments.state.value.busy && payments.state.value.pending == null && !payments.state.value.blocked

  private fun directory(network: WalletNetwork) = File(root, "wallets/${network.wire}")
  private fun paymentOperations(network: WalletNetwork, epoch: Long) = PaymentOperations(scope,
    NativePaymentGateway(client) { preferences.network(network).credit },
    FilePaymentJournal(File(directory(network).apply { mkdirs() }, "pending-payment.json")),
    allowed = { foreground && epoch == generation && state.value.network == network && state.value.phase == WalletPhase.OPEN },
    onEntry = { if (epoch == generation) upsert(it) }, network = network)

  fun resume() {
    foreground = true
    diagnostics.begin(state.value.network)
    scope.launch { lifecycle.withLock {
      if (!foreground) return@withLock
      try {
        if (!client.isRunning) startCurrent()
        val info = client.getInfo()
        if (!foreground) return@withLock
        diagnostics.stage("Daemon available")
        mutable.update { it.copy(info = info) }
        when {
          info.walletState == WalletState.NONE -> mutable.update { it.copy(phase = WalletPhase.SETUP) }
          mutable.value.phase == WalletPhase.OPEN -> startObservations()
          !state.value.authentication || pendingUnlock == state.value.network -> openCurrent(false)
          else -> mutable.update { it.copy(phase = WalletPhase.LOCKED) }
        }
      } catch (error: Exception) { fail(error) }
    } }
  }

  fun pause() {
    foreground = false
    diagnostics.finish("Paused")
    observations?.cancel()
    mutable.update { it.copy(phase = if (it.phase == WalletPhase.OPEN && it.authentication) WalletPhase.LOCKED else it.phase) }
    scope.launch { lifecycle.withLock {
      observations?.join(); observations = null
      if (client.isRunning) reads.withLock { runCatching { client.setHostForeground(false) } }
    } }
  }

  /** A credential fallback may return before onStart; consume its success there. */
  fun open(create: Boolean = false, mnemonic: List<String> = emptyList()) {
    val selected = state.value.network
    if (!create) pendingUnlock = selected
    scope.launch { lifecycle.withLock {
      if (!foreground || state.value.network != selected) return@withLock
      try { openCurrent(create, mnemonic) } catch (error: Exception) { fail(error) }
    } }
  }

  private suspend fun openCurrent(create: Boolean, mnemonic: List<String> = emptyList()) {
    mutable.update { it.copy(phase = WalletPhase.OPENING, error = null) }
    val selected = state.value.network
    if (create || client.getInfo().walletState == WalletState.LOCKED) {
      val password = withContext(Dispatchers.IO) { vault.password(create, selected) }
      try {
        if (create) {
          val result = client.createWallet(password, mnemonic)
          // No phrase copy is persisted. Existing legacy encrypted files stay intact.
          if (mnemonic.isEmpty()) mutable.update { it.copy(recoveryWords = result.mnemonic) }
        } else client.unlockWallet(password)
      } finally { password.fill(0) }
    }
    pendingUnlock = null
    if (!foreground) { mutable.update { it.copy(phase = WalletPhase.LOCKED) }; return }
    diagnostics.stage("Wallet available")
    mutable.update { it.copy(phase = WalletPhase.OPEN) }
    startObservations()
  }

  fun acknowledgeBackup() { mutable.update { it.copy(recoveryWords = null) } }

  private suspend fun startCurrent() {
    mutable.update { it.copy(phase = WalletPhase.OPENING, error = null) }
    val network = state.value.network
    client.start(preferences.network(network).config(network, directory(network).absolutePath, preferences.captureLevel))
  }

  fun switchNetwork(network: WalletNetwork) {
    if (network == state.value.network || !canChangeWallet) return
    scope.launch { lifecycle.withLock {
      if (!canChangeWallet) return@withLock
      transition(network)
    } }
  }

  /** Stop old observers before the singleton changes network; never replay work. */
  private suspend fun transition(network: WalletNetwork, endpoints: EndpointOverrides? = null) {
    mutable.update { it.copy(phase = WalletPhase.OPENING, error = null) }
    pendingUnlock = null
    try {
      observations?.cancelAndJoin(); observations = null
      reads.withLock { client.stop() }
      if (endpoints != null) preferences.endpoints(network, endpoints)
      preferences.select(network)
      diagnostics.finish("Network changed")
      if (foreground) diagnostics.begin(network)
      generation++
      payments = paymentOperations(network, generation)
      mutable.value = WalletUiState(network = network, settings = preferences.network(network),
        appearance = preferences.appearance, authentication = preferences.authentication, captureLevel = preferences.captureLevel)
      startCurrent()
      val info = client.getInfo()
      mutable.update { it.copy(info = info, phase = if (info.walletState == WalletState.NONE) WalletPhase.SETUP else WalletPhase.LOCKED) }
      if (info.walletState != WalletState.NONE && !state.value.authentication && foreground) openCurrent(false)
    } catch (error: Exception) { fail(error) }
  }

  fun saveConnection(value: EndpointOverrides) {
    if (!canChangeWallet) return
    val valid = try { value.validated() } catch (error: Exception) { reportError(error); return }
    scope.launch { lifecycle.withLock {
      if (canChangeWallet) transition(state.value.network, valid)
    } }
  }

  fun retry() {
    if (!canChangeWallet) return
    scope.launch { lifecycle.withLock { if (canChangeWallet) transition(state.value.network) } }
  }

  fun setCaptureLevel(value: CaptureLevel) = preferenceChange {
    preferences.captureLevel(value); mutable.update { it.copy(captureLevel = value) }
  }
  fun setAppearance(value: WalletAppearance) = preferenceChange {
    preferences.appearance(value); mutable.update { it.copy(appearance = value) }
  }
  fun setAuthentication(value: Boolean) = preferenceChange {
    preferences.authentication(value); mutable.update { it.copy(authentication = value) }
    if (!value && state.value.phase == WalletPhase.LOCKED) open()
  }
  fun saveCredit(value: CreditLimits) = preferenceChange {
    preferences.credit(state.value.network, value)
    mutable.update { it.copy(settings = preferences.network(it.network)) }
  }
  private fun preferenceChange(action: () -> Unit) {
    try { action() } catch (error: Exception) { reportError(error) }
  }

  private fun startObservations() {
    if (!foreground || observations?.isActive == true) return
    val epoch = generation
    observations = scope.launch {
      launch {
        while (isActive) {
          try {
            diagnostics.stage("Starting ingress")
            client.setHostForeground(true)
            diagnostics.stage("Ingress started")
            client.activity(includeExisting = true).collect { entry -> if (epoch == generation) upsert(entry) }
          } catch (error: CancellationException) { throw error }
          catch (_: Exception) { delay(3_000) }
        }
      }
      while (isActive) { refresh(); delay(5_000) }
    }
  }

  suspend fun refresh() = reads.withLock {
    val epoch = generation
    if (state.value.phase != WalletPhase.OPEN) return@withLock
    supervisorScope {
      val balance = launch {
        try { val value = client.balance(); if (epoch == generation) { mutable.update { it.copy(balance = value) }; diagnostics.stage("Balance loaded") } }
        catch (error: CancellationException) { throw error }
        catch (_: Exception) { /* Keep the last observed balance while reconnecting. */ }
      }
      val activity = launch {
        try {
          val before = mutable.value.activity.associateBy { it.id }
          val result = client.list(limit = 1000).activity ?: error("Activity unavailable")
          if (epoch == generation) mutable.update { current ->
            current.copy(activity = mergeActivitySnapshot(before, result.entries, current.activity), activityLoaded = true, error = null)
          }
          if (epoch == generation) diagnostics.stage("Activity loaded")
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { if (epoch == generation) fail(error, fatal = false) }
      }
      launch { runCatching { client.getInfo() }.onSuccess { info -> if (epoch == generation) mutable.update { it.copy(info = info) } } }
      balance.join(); activity.join()
      if (epoch == generation) payments.reconcile(mutable.value.activity)
    }
  }

  suspend fun <T> inspect(action: suspend (WalletClient) -> T): T {
    val epoch = generation
    return reads.withLock {
      check(state.value.phase == WalletPhase.OPEN) { "Unlock this wallet first." }
      val value = action(client)
      check(epoch == generation) { "Wallet changed." }
      value
    }
  }
  fun dismissError() { mutable.update { it.copy(error = null) } }
  fun reportError(error: Throwable) = fail(error, fatal = false)
  fun upsert(entry: Entry) { mutable.update { it.copy(activity = it.activity.filterNot { old -> old.id == entry.id } + entry) } }
  private fun fail(error: Throwable, fatal: Boolean = true) {
    if (error is CancellationException) throw error
    if (fatal) diagnostics.finish("Failed")
    mutable.update { it.copy(phase = if (fatal) WalletPhase.ERROR else it.phase, error = error.message ?: "Wallet unavailable") }
  }
}

enum class WalletPhase { OPENING, SETUP, LOCKED, OPEN, ERROR }
data class WalletUiState(
  val phase: WalletPhase = WalletPhase.OPENING,
  val network: WalletNetwork = WalletNetwork.SIGNET,
  val settings: NetworkSettings = NetworkSettings(),
  val appearance: WalletAppearance = WalletAppearance.SYSTEM,
  val authentication: Boolean = true,
  val captureLevel: CaptureLevel = CaptureLevel.INFO,
  val recoveryWords: List<String>? = null,
  val info: Info? = null,
  val balance: Balance? = null,
  val activity: List<Entry> = emptyList(),
  val activityLoaded: Boolean = false,
  val error: String? = null,
)
