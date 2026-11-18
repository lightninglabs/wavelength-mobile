package engineering.lightning.wavelength.data

import android.content.Context
import android.os.UserManager
import engineering.lightning.wavelength.background.*
import kotlinx.coroutines.flow.first
import engineering.lightning.wavewalletdk.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

/** One daemon with serialized ownership when moving between isolated wallets. */
class WalletSession(private val context: Context) {
  val client = WalletClient()
  val diagnostics = DiagnosticRuns()
  val backgroundHistory = BackgroundJournal(File(context.noBackupFilesDir,"background-history.json"))
  internal val relay = RelayRegistration(context)
  val notices = WalletNotices(context)
  private val root = context.noBackupFilesDir
  private val vault = WalletVault(context)
  private val preferences = WalletPreferences(context)
  val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private val lifecycle = Mutex()
  private val reads = Mutex()
  private val maintenance = MaintenanceOwner(scope,lifecycle,observedRelease = { lease -> backgroundHistory.stage(lease.id,"Host owner released") }) { lease ->
    if (lease.coldStarting) client.stop() else client.cancelMaintenanceWindow(lease.id)
  }
  private val mutable = MutableStateFlow(WalletUiState(network = preferences.selectedNetwork,
    settings = preferences.network(preferences.selectedNetwork), appearance = preferences.appearance,
    authentication = preferences.authentication, captureLevel = preferences.captureLevel))
  val state = mutable.asStateFlow()
  private var observations: Job? = null
  private var foreground = false
  private var history = ActivityHistory()
  private var activityCursor = 0L
  private val activitySignals = Channel<Unit>(Channel.CONFLATED)
  private var notificationLookup: Job? = null
  private val creation = WalletCreation(
    generate = { client.generateSeed().mnemonic },
    initialize = { words ->
      val password = withContext(Dispatchers.IO) { vault.password(true, state.value.network) }
      try { client.createWallet(password, words) } finally { password.fill(0) }
    },
  )
  private var generation = 0L
  private var pendingNotification: Pair<WalletNetwork,String>? = null
  private var pendingUnlock: WalletNetwork? = null
  var payments = paymentOperations(mutable.value.network, generation)
    private set
  private var fundsBusy = false
  val canChangeWallet: Boolean get() = !fundsBusy && maintenance.active == null && state.value.phase != WalletPhase.OPENING && state.value.recoveryWords == null &&
    !payments.state.value.busy && payments.state.value.pending == null && !payments.state.value.blocked

  private fun directory(network: WalletNetwork) = File(root, "wallets/${network.wire}")
  private fun paymentOperations(network: WalletNetwork, epoch: Long) = PaymentOperations(scope,
    NativePaymentGateway(client) { preferences.network(network).credit },
    FilePaymentJournal(File(directory(network).apply { mkdirs() }, "pending-payment.json")),
    allowed = { !fundsBusy && foreground && epoch == generation && state.value.network == network && state.value.phase == WalletPhase.OPEN },
    onEntry = { if (epoch == generation) observeActivity(it) }, network = network,
    receiptConsentEpoch = {
      notices.consent(network)?.takeIf { it.identity == state.value.info?.identityPubKey &&
        it.connection == connectionFingerprint() }?.epoch
    },
    enroll = { pending, result ->
      notices.admission(network, state.value.info?.identityPubKey.orEmpty(), connectionFingerprint(), pending.amountSat)?.invoke(result)
    })

  fun resume() {
    foreground = true
    maintenance.interrupt()
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
          state.value.phase == WalletPhase.BACKUP -> Unit
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
    if (state.value.phase == WalletPhase.BACKUP) {
      creation.discard()
      mutable.update { it.copy(phase = WalletPhase.SETUP, recoveryWords = null) }
    }
    diagnostics.finish("Paused")
    observations?.cancel()
    notificationLookup?.cancel()
    mutable.update { it.copy(phase = if (it.phase == WalletPhase.OPEN && it.authentication) WalletPhase.LOCKED else it.phase) }
    scope.launch {
      // Let already admitted native payment calls return before pausing intake.
      payments.state.first { !it.busy }
      lifecycle.withLock {
        if (foreground) return@withLock
        observations?.join(); observations = null
        if (client.isRunning) reads.withLock { runCatching { client.setHostForeground(false) } }
      }
    }
  }

  /** A credential fallback may return before onStart; consume its success there. */
  fun open(create: Boolean = false, mnemonic: List<String> = emptyList()) {
    val selected = state.value.network
    if (!create) pendingUnlock = selected
    scope.launch { lifecycle.withLock {
      if (!foreground || state.value.network != selected || (create && state.value.phase != WalletPhase.SETUP)) return@withLock
      try { openCurrent(create, mnemonic) } catch (error: Exception) { fail(error) }
    } }
  }

  private suspend fun openCurrent(create: Boolean, mnemonic: List<String> = emptyList()) {
    mutable.update { it.copy(phase = WalletPhase.OPENING, error = null) }
    if (create && mnemonic.isEmpty()) {
      val words = creation.prepare()
      if (foreground) mutable.update { it.copy(phase = WalletPhase.BACKUP, recoveryWords = words) }
      else {
        creation.discard()
        mutable.update { it.copy(phase = WalletPhase.SETUP) }
      }
      return
    }
    if (create) creation.restore(mnemonic)
    else if (client.getInfo().walletState == WalletState.LOCKED) {
      val password = withContext(Dispatchers.IO) { vault.password(false, state.value.network) }
      try { client.unlockWallet(password) } finally { password.fill(0) }
    }
    opened()
  }

  private fun opened() {
    pendingUnlock = null
    if (!foreground) { mutable.update { it.copy(phase = WalletPhase.LOCKED) }; return }
    diagnostics.stage("Wallet available")
    mutable.update { it.copy(phase = WalletPhase.OPEN) }
    startObservations()
  }

  fun acknowledgeBackup() {
    val selected = state.value.network
    scope.launch { lifecycle.withLock {
      if (!foreground || state.value.network != selected || state.value.phase != WalletPhase.BACKUP) return@withLock
      mutable.update { it.copy(phase = WalletPhase.OPENING, recoveryWords = null, error = null) }
      try { creation.acknowledge(); opened() } catch (error: Exception) { fail(error) }
    } }
  }

  private suspend fun startCurrent() {
    history = ActivityHistory()
    activityCursor = 0
    mutable.update { it.copy(phase = WalletPhase.OPENING, error = null, history = history.state,
      notificationTarget = null, notificationEntry = null) }
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
      notificationLookup?.cancelAndJoin(); notificationLookup = null
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
    relay.schedule(afterCurrent = true)
    val pager = history
    observations = scope.launch {
      launch {
        while (isActive) {
          try {
            diagnostics.stage("Starting ingress")
            client.setHostForeground(true)
            diagnostics.stage("Ingress started")
            client.activity().collect { activitySignals.trySend(Unit) }
          } catch (error: CancellationException) { throw error }
          catch (_: Exception) { /* The periodic read catches missed signals. */ }
          delay(3_000)
        }
      }
      launch {
        for (signal in activitySignals) reads.withLock {
          if (activityIsCurrent(pager) && pager.state.loaded) readActivityChanges(pager)
        }
      }
      while (isActive) { refresh(); delay(5_000) }
    }
    resolveNotification()
  }

  suspend fun refresh() = reads.withLock {
    val epoch = generation
    val pager = history
    if (!activityIsCurrent(pager)) return@withLock
    supervisorScope {
      val balance = launch {
        try { val value = client.balance(); if (epoch == generation) { mutable.update { it.copy(balance = value) }; diagnostics.stage("Balance loaded") } }
        catch (error: CancellationException) { throw error }
        catch (_: Exception) { /* Keep the last observed balance while reconnecting. */ }
      }
      launch {
        if (!pager.state.loaded) readActivityPage(pager)
        else {
          val head = activityRead { client.list(limit = 1).activity }
          if (head != null && activityIsCurrent(pager)) {
            pager.updateOverlay(head.entries)
            publishHistory()
          }
        }
        if (activityIsCurrent(pager) && pager.state.loaded) readActivityChanges(pager)
      }
      launch { runCatching { client.getInfo() }.onSuccess { info -> if (epoch == generation) mutable.update { it.copy(info = info) } } }
      launch {
        if (payments.state.value.busy || (payments.state.value.pending == null && payments.state.value.unresolved.isEmpty())) return@launch
        activityRead { payments.checkPending() }
      }
      launch {
        val inventory = activityRead { client.recoveryInventory() } ?: return@launch
        if (!activityIsCurrent(pager)) return@launch
        val height = state.value.info?.blockHeight ?: 0
        val recoverable = inventory.vtxos.filter { it.status == "expired" ||
          (it.status == "live" && it.batchExpiry.toLong() in 1..height) }.sumOf { it.amountSat }
        mutable.update { it.copy(recoverableSat = recoverable) }
      }
      balance.join()
    }
  }

  fun loadOlderActivity() {
    val pager = history
    val requested = pager.state
    if (requested.loading || (requested.loaded && requested.nextCursor == null)) return
    scope.launch {
      reads.withLock {
        if (!activityIsCurrent(pager) || requested.loaded != pager.state.loaded ||
          requested.nextCursor != pager.state.nextCursor) return@withLock
        readActivityPage(pager)
        if (activityIsCurrent(pager) && pager.state.loaded) readActivityChanges(pager)
      }
    }
  }

  private fun activityIsCurrent(pager: ActivityHistory) =
    foreground && history === pager && state.value.phase == WalletPhase.OPEN

  private fun publishHistory() { mutable.update { it.copy(history = history.state) } }

  private suspend fun readActivityPage(pager: ActivityHistory) {
    val requested = pager.state
    var failed = false
    pager.loading()
    publishHistory()
    try {
      val baseline = if (requested.loaded) activityCursor else client.activityCursor()
      if (!activityIsCurrent(pager)) return
      val page = client.list(limit = ActivityHistory.PAGE_SIZE, cursor = requested.nextCursor.orEmpty()).activity
        ?: error("Activity unavailable")
      if (!activityIsCurrent(pager)) return
      pager.append(page, requested.nextCursor)
      activityCursor = baseline
      if (!requested.loaded) {
        diagnostics.stage("Activity loaded")
        pager.state.entries.forEach(::suppressVisibleReceipt)
      }
    } catch (error: CancellationException) {
      throw error
    } catch (_: Exception) {
      failed = true
    } finally {
      if (history === pager) {
        pager.finish(failed)
        publishHistory()
      }
    }
  }

  private suspend fun readActivityChanges(pager: ActivityHistory) {
    var through = 0L
    repeat(4) {
      val batch = activityRead { client.readActivityBatch(activityCursor, through) } ?: return
      if (!activityIsCurrent(pager)) return
      pager.mergeChanges(batch.entries)
      publishHistory()
      batch.entries.distinctBy { it.id }.forEach { entry ->
        suppressVisibleReceipt(entry)
        if (state.value.notificationEntry?.id == entry.id) {
          mutable.update { it.copy(notificationEntry = entry) }
        }
      }
      activityCursor = batch.nextCursor
      if (!batch.hasMore) return
      through = batch.highWater
    }
    // Release the read lock between passes so paging and other reads can run.
    activitySignals.trySend(Unit)
  }

  private suspend fun <T> activityRead(read: suspend () -> T): T? = try {
    read()
  } catch (error: CancellationException) {
    throw error
  } catch (_: Exception) {
    null
  }

  fun openNotification(network: String?, receipt: String?) {
    val selected = WalletNetwork.entries.firstOrNull { it.wire == network } ?: return
    if (receipt == null || !notices.knownReceipt(selected,receipt)) return
    pendingNotification = selected to receipt
    if (selected != state.value.network) reportError(IllegalStateException("Open ${selected.title} to view this payment."))
    else resolveNotification()
  }

  private fun resolveNotification() {
    val target = pendingNotification ?: return
    val pager = history
    if (target.first != state.value.network || !activityIsCurrent(pager)) return
    notificationLookup?.cancel()
    notificationLookup = scope.launch {
      try {
        // A tap can target an unloaded row. Resolve it separately so the
        // home pager keeps the reader's position and its own continuation.
        var entry = state.value.activity.firstOrNull { it.id == target.second }
        var cursor = ""
        while (entry == null) {
          val page = reads.withLock {
            if (!activityIsCurrent(pager) || pendingNotification != target) return@launch
            client.list(kinds = listOf("receive"), limit = 100, cursor = cursor).activity
              ?: error("Activity unavailable")
          }
          entry = page.entries.firstOrNull { it.id == target.second }
          if (!page.hasMore) break
          check(page.nextCursor.isNotEmpty() && page.nextCursor != cursor)
          cursor = page.nextCursor
        }
        if (!activityIsCurrent(pager) || pendingNotification != target) return@launch
        if (entry == null) {
          pendingNotification = null
          reportError(IllegalStateException("This payment is no longer available."))
        } else {
          mutable.update { it.copy(notificationEntry = entry, notificationTarget = target.second) }
        }
      } catch (error: CancellationException) {
        throw error
      } catch (_: Exception) {
        if (activityIsCurrent(pager) && pendingNotification == target) {
          reportError(IllegalStateException("Couldn’t open this payment. Tap the notification to retry."))
        }
      }
    }
  }

  fun consumeNotification() { pendingNotification = null; mutable.update { it.copy(notificationTarget = null) } }

  fun connectionFingerprint(): String {
    val settings = state.value.settings.endpoints
    val raw = "${state.value.network.wire}\u0000${settings.operator}\u0000${settings.swap}\u0000${settings.esplora}"
    return java.security.MessageDigest.getInstance("SHA-256").digest(raw.toByteArray()).joinToString("") { "%02x".format(it) }
  }

  fun configureNotifications(enabled: Boolean, amounts: Boolean = false) = preferenceChange {
    if (!enabled && relay.configured && state.value.network.wire == engineering.lightning.wavelength.BuildConfig.FIREBASE_RELAY_NETWORK) {
      relay.select(state.value.network.wire,state.value.info?.identityPubKey.orEmpty(),connectionFingerprint(),false)
    }
    notices.configure(state.value.network,state.value.info?.identityPubKey.orEmpty(),connectionFingerprint(),enabled,amounts)
  }

  internal suspend fun signRelayGrant(target: PushTarget, request: NotificationFeedGrant): NotificationFeedResult =
    withContext(Dispatchers.Main.immediate) {
      lifecycle.withLock {
        val current = state.value
        val consent = notices.consent(current.network)
        if (!(foreground && current.phase == WalletPhase.OPEN && current.network.wire == target.network &&
          current.settings.endpoints == EndpointOverrides() && connectionFingerprint() == target.connection &&
          current.info?.identityPubKey == target.identity)) throw RelayWalletUnavailable()
        if (!request.remove && (consent?.identity != target.identity || consent.connection != target.connection ||
          !relay.stillDesired(target))) throw RelayWalletUnavailable()
        val native = client.getInfo()
        check(native.identityPubKey == target.identity)
        client.setNotificationFeedGrant(request)
      }
    }

  /** One native owner across cold start, expiry, foreground takeover and cleanup. */
  suspend fun runBackground(trigger: String, expectedNetwork: String? = null, expectedIdentity: String? = null, wake: BackgroundWakeContext? = null): BackgroundOutcome = withContext(Dispatchers.Main.immediate) {
    maintenance.run { lease ->
      val network = state.value.network
      if (expectedNetwork != null && expectedNetwork != network.wire) {
        return@run BackgroundOutcome("Rejected · Another network is selected")
      }
      backgroundHistory.begin(lease.id,network,trigger,wake)
      val preparationStart = backgroundHistory.mark()
      var outcome = BackgroundOutcome("Not admitted")
      var cold = false
      try {
        if (foreground || payments.state.value.busy || state.value.recoveryWords != null ||
          !context.getSystemService(UserManager::class.java).isUserUnlocked) {
          outcome = BackgroundOutcome(when {
            foreground -> "Skipped · App in foreground"
            payments.state.value.busy -> "Skipped · Payment in progress"
            state.value.recoveryWords != null -> "Skipped · Recovery backup open"
            else -> "Skipped · Device has not been unlocked after boot"
          })
          return@run outcome
        }
        observations?.cancelAndJoin(); observations = null
        reads.withLock {
          fun permitted() = !foreground && !lease.expired && state.value.network == network
          if (!permitted()) return@withLock
          if (!client.isRunning) {
            // Read before opening a database. Background never creates a wallet
            // or prompts for credentials, and it never grants a UI session.
            val password = backgroundHistory.measure(lease.id,"Credential read") { withContext(Dispatchers.IO) { vault.password(false,network) } }
            try {
              if (!permitted()) return@withLock
              cold = true; lease.coldStarting = true
              backgroundHistory.context(lease.id,startup = "Cold")
              backgroundHistory.stage(lease.id,"Cold startup")
              backgroundHistory.measure(lease.id,"Daemon startup") { startCurrent() }
              if (!permitted()) return@withLock
              val info = client.getInfo()
              check(info.walletState != WalletState.NONE) { "Wallet has not been created" }
              if (info.walletState == WalletState.LOCKED) backgroundHistory.measure(lease.id,"Wallet unlock") { client.unlockWallet(password) }
            } finally { password.fill(0) }
          } else {
            backgroundHistory.context(lease.id,startup = "Retained")
            backgroundHistory.stage(lease.id,"Retained runtime")
            // A retained daemon may have been started at the locked screen.
            if (client.getInfo().walletState == WalletState.LOCKED) {
              val password = backgroundHistory.measure(lease.id,"Credential read") { withContext(Dispatchers.IO) { vault.password(false,network) } }
              try { if (permitted()) backgroundHistory.measure(lease.id,"Wallet unlock") { client.unlockWallet(password) } } finally { password.fill(0) }
            }
          }
          if (!permitted()) return@withLock
          val info = client.getInfo()
          check(info.walletState != WalletState.NONE && info.identityPubKey.isNotBlank() &&
            (expectedIdentity == null || expectedIdentity == info.identityPubKey)) { "Wallet unavailable" }
          mutable.update { it.copy(info = info, phase = WalletPhase.LOCKED) }
          backgroundHistory.measure(lease.id,"Pause foreground ingress") { client.setHostForeground(false) }
          lease.coldStarting = false
          if (!permitted()) return@withLock
          backgroundHistory.stage(lease.id,"Preparation; UI locked",backgroundHistory.duration(preparationStart))
          backgroundHistory.stage(lease.id,"Native maintenance window")
          backgroundHistory.context(lease.id,nativeBudget = BackgroundLease.NATIVE_CEILING_SECONDS.toInt())
          val enrolled = notices.pending(network, info.identityPubKey, connectionFingerprint())
          val result = coroutineScope {
            // The native pump may run until host expiry. Check already-admitted
            // receipts while it advances the wallet and still owns its lease.
            val window = async {
              backgroundHistory.measure(lease.id, "Maintenance window") {
                if (enrolled.isEmpty()) client.runMaintenanceWindow(lease.id, BackgroundLease.NATIVE_CEILING_SECONDS)
                else client.runWorkWindow(lease.id, enrolled.map { it.reference }, BackgroundLease.NATIVE_CEILING_SECONDS)
              }
            }
            val remaining = enrolled.toMutableList()
            while (remaining.isNotEmpty() && permitted()) {
              val proofs = client.readLightningReceipts(remaining.map { it.reference }, enrolled.first().consent.since)
              if (!permitted()) break
              remaining.removeAll { entry ->
                val proof = proofs.firstOrNull { it.reference == entry.reference } ?: return@removeAll false
                notices.present(network, entry, proof, visible = foreground)
                proof.state == "complete"
              }
              backgroundHistory.receipts(lease.id, proofs.size, proofs.count { it.state == "complete" })
              if (window.isCompleted || remaining.isEmpty()) break
              withTimeoutOrNull(3000L) { window.await() }
            }
            window.await()
          }
          backgroundHistory.nativeResult(lease.id,result)
          if (!permitted()) return@withLock
          outcome = BackgroundOutcome(when {
            result.budgetExhausted -> "Budget exhausted"
            result.interrupted -> "Interrupted"
            result.needsForeground -> "Needs foreground"
            else -> "Window completed"
          },result.batches > 0 || result.maintenanceChecked > 0)

        }
        if (lease.expired || foreground) outcome = BackgroundOutcome(lease.cancellationReason?.label ?: "Foreground takeover")
        outcome
      } catch (_: Exception) {
        outcome = BackgroundOutcome(lease.cancellationReason?.label ?: "Preparation or native call failed")
        outcome
      } finally {
        // Only stop failed cold preparation. A prepared native runtime survives
        // bounded-window expiry, preserving existing signing/domain owners.
        if (cold && lease.coldStarting) runCatching { backgroundHistory.measure(lease.id,"Cold preparation cleanup") { client.stop() } }
        if (!foreground && state.value.phase == WalletPhase.OPENING) mutable.update { it.copy(phase = WalletPhase.LOCKED) }
        backgroundHistory.finish(lease.id,lease.cancellationReason?.label ?: outcome.label)
      }
    }
  }

  internal fun fundsDirectory(network: WalletNetwork) = directory(network)

  /** Serialize one reviewed action against lifecycle changes and other sends. */
  internal suspend fun <T> fundsAction(network: WalletNetwork, action: suspend (WalletClient, () -> Unit) -> T): T {
    val epoch = generation
    fun requireOwner() = check(foreground && epoch == generation && state.value.network == network &&
      state.value.phase == WalletPhase.OPEN) { "Reopen this wallet and review again." }
    requireOwner()
    check(canChangeWallet) { "Check the current wallet operation first." }
    fundsBusy = true
    try {
      return reads.withLock {
        requireOwner()
        // Once admitted, navigation cannot discard the reply before the caller journals it.
        withContext(NonCancellable) { action(client, ::requireOwner) }
      }
    } finally { fundsBusy = false }
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
  private fun observeActivity(entry: Entry) {
    suppressVisibleReceipt(entry)
    activitySignals.trySend(Unit)
  }

  private fun suppressVisibleReceipt(entry: Entry) {
    if (foreground && state.value.phase == WalletPhase.OPEN && entry.status == "complete")
      runCatching { notices.suppressVisible(state.value.network, entry.id) }.onFailure(::reportError)
  }
  private fun fail(error: Throwable, fatal: Boolean = true) {
    if (error is CancellationException) throw error
    if (fatal) pendingUnlock = null
    if (fatal) diagnostics.finish("Failed")
    mutable.update { it.copy(phase = if (fatal) WalletPhase.ERROR else it.phase, error = error.message ?: "Wallet unavailable") }
  }
}

enum class WalletPhase { OPENING, SETUP, BACKUP, LOCKED, OPEN, ERROR }
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
  val recoverableSat: Long = 0,
  val history: ActivityHistoryState = ActivityHistoryState(),
  val error: String? = null,
  val notificationTarget: String? = null,
  val notificationEntry: Entry? = null,
) {
  val activity: List<Entry> get() = history.entries
}
