import UIKit
import Combine
import Foundation
import WalletKit
import LocalAuthentication
import Security

private struct ReceiveCreationUncertainError: LocalizedError {
    var errorDescription: String? {
        "The receive request ended before Wavelength could confirm the result. Wavelength couldn’t find a newly created invoice in Activity. Check Activity before trying again."
    }
}

struct RefreshOperation: Codable {
    let outpoints: [String]
    let amountSat: Int64
    var status: String
    var canRetry: Bool? = nil
}

@MainActor
final class WalletStore: ObservableObject {
    @Published private(set) var phase: WalletPhase = .idle
    @Published private(set) var info: Info?
    @Published private(set) var balance: Balance?
    @Published private(set) var activity: [Entry] = []
    @Published private(set) var isWorking = false
    @Published private(set) var unlockStage: WalletUnlockStage?
    @Published private(set) var activityLoaded = false
    @Published var pendingMnemonic: [String]?
    @Published var alertMessage: String?
    @Published private(set) var isSessionLocked = false
    @Published private(set) var biometricUnlockEnabled = false
    @Published private(set) var pendingDispatch: PendingDispatch?
    @Published private(set) var sweepOperation: SweepOperation?
    @Published private(set) var unresolvedDispatches: [PendingDispatch] = []
    @Published private(set) var unresolvedSweeps: [SweepOperation] = []
    @Published private(set) var refreshOperation: RefreshOperation?
    @Published private(set) var recoveryInventory: [WalletVTXO] = []
    @Published private(set) var onchainHistory: [OnchainTx] = []
    @Published private(set) var recoveryJobs: [ExitSummaryEntry] = []
    @Published private(set) var maxCreditSat: UInt64 = 10_000
    @Published private(set) var maxCreditTopupSat: UInt64 = 10_000
    private var sessionPassword: Data?
    private let authenticate: () async throws -> Void
    private let applicationIsActive: @MainActor () -> Bool
    private let waitForForeground: @MainActor () async throws -> Void
    private var authenticationEpoch = 0
    @Published private(set) var managedKeyUnavailable = false
    private var backgroundPreparation: Task<Bool, Never>?
    private var backgroundPreparationID: String?
    private var backgroundStartedRuntime = false

    /// Only unmigrated wallets need a user-entered password. Keep the
    /// credential itself encrypted and device-managed after migration.
    var needsPasswordMigration: Bool {
        hasPasswordFallback && !KeychainStore.contains(account: keychainAccount)
    }

    var hasPasswordFallback: Bool {
        defaults.object(forKey: preferenceKey("userPassword")) == nil ||
            defaults.bool(forKey: preferenceKey("userPassword"))
    }



    @Published private(set) var network: WalletNetwork
    @Published private(set) var operatorAddress: String
    @Published private(set) var swapServerAddress: String
    @Published private(set) var esploraURL: String

    private let client: WalletClient
    private let startClient: (WalletConfig) async throws -> Void
    private let stopClient: () async throws -> Void
    private let dataRoot: URL?
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var generation = 0
    @Published private var stateCreatingCallCount = 0
    private var foregroundRestartPending = false
    private var receiptBackgroundRequested = false
    private var receiptWindowWork: Task<ReceiptWindowResult, Error>?

    init(defaults: UserDefaults = .standard, client: WalletClient = WalletClient(), dataRoot: URL? = nil,
         authenticate: @escaping () async throws -> Void = WalletAuthentication.authenticate,
         waitForForeground: @escaping @MainActor () async throws -> Void = WalletAuthentication.waitForForeground,
         applicationIsActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
         startClient: ((WalletConfig) async throws -> Void)? = nil,
         stopClient: (() async throws -> Void)? = nil) {
        self.defaults = defaults
        self.client = client
        self.startClient = startClient ?? { try await client.start($0) }
        self.stopClient = stopClient ?? { try await client.stop() }
        self.dataRoot = dataRoot
        self.authenticate = authenticate
        self.waitForForeground = waitForForeground
        self.applicationIsActive = applicationIsActive
        #if DEBUG
        let debugRegtest = ProcessInfo.processInfo.environment["WAVELENGTH_REGTEST"] == "1"
        #else
        let debugRegtest = false
        #endif
        let selected = debugRegtest
            ? WalletNetwork.regtest.rawValue
            : defaults.string(forKey: "selectedNetwork") ?? WalletNetwork.signet.rawValue
        network = WalletNetwork(rawValue: selected) ?? .signet
        operatorAddress = ""
        swapServerAddress = ""
        esploraURL = ""
        loadEndpointOverrides()
        loadNetworkPreferences()
        #if DEBUG
        if debugRegtest {
            let environment = ProcessInfo.processInfo.environment
            operatorAddress = environment["WAVELENGTH_OPERATOR_ADDRESS"] ?? operatorAddress
            swapServerAddress = environment["WAVELENGTH_SWAP_ADDRESS"] ?? swapServerAddress
            esploraURL = environment["WAVELENGTH_ESPLORA_URL"] ?? esploraURL
        }
        #endif
    }

    deinit {
        refreshTask?.cancel()
        activityTask?.cancel()
    }

    var visibleActivity: [Entry] { WalletActivityPresentation.entries(activity) }

    var canChangeNetwork: Bool { stateCreatingCallCount == 0 && !isWorking && backgroundPreparation == nil && phase != .starting }

    var isReady: Bool { phase == .ready }
    var isSyncing: Bool { phase == .syncing }
    var canUnlockWallet: Bool {
        phase == .needsUnlock || (phase.isWalletAvailable && isSessionLocked)
    }
    var confirmedBalanceSat: Int64 { balance?.confirmedSat ?? 0 }
    var pendingInSat: Int64 { balance?.pendingInSat ?? 0 }
    var pendingOutSat: Int64 { balance?.pendingOutSat ?? 0 }

    func transactionExplorerURL(txid: String) -> URL? {
        customEsploraResourceURL(kind: "tx", identifier: txid) ??
            network.transactionURL(txid: txid)
    }

    func addressExplorerURL(address: String) -> URL? {
        customEsploraResourceURL(kind: "address", identifier: address) ??
            network.addressURL(address: address)
    }

    /// Public networks use the SDK defaults when no override is saved.
    /// Local regtest still requires an explicitly configured operator.
    var operatorAvailable: Bool {
        if network == .regtest {
            return !operatorAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    /// Lightning receive/send additionally requires the swap service.
    var offchainAvailable: Bool {
        if network == .regtest {
            return operatorAvailable &&
                !swapServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    func start() async {
        if let preparation = backgroundPreparation {
            _ = await preparation.value
            await resumeAfterBackground()
            return
        }
        guard phase != .starting, stateCreatingCallCount == 0 else { return }
        generation += 1
        let currentGeneration = generation
        stopMonitoring()
        phase = .starting
        managedKeyUnavailable = false
        info = nil
        balance = nil
        activity = []
        activityLoaded = false

        do {
            // A non-running singleton may still own shutdown or cancelled
            // startup. Stop is a no-op only after that cleanup has joined.
            try await stopClient()
            let config = try walletConfig()
            try await startClient(config)
            guard currentGeneration == generation else { return }
            try await resolveLifecycle()
        } catch {
            guard currentGeneration == generation else { return }
            phase = .failed(error.walletMessage)
        }
    }

    func retry() {
        Task { await start() }
    }

    /// Re-dial transports after iOS has frozen the embedded daemon in the
    /// background. If a state-creating call is still returning, defer teardown
    /// until its outcome can be reconciled instead of cancelling it midway.
    func resumeAfterBackground() async {
        receiptBackgroundRequested = false
        if backgroundPreparation == nil, stateCreatingCallCount > 0 {
            foregroundRestartPending = true
            return
        }
        if let preparation = backgroundPreparation { _ = await preparation.value }
        guard applicationIsActive() else { return }
        if await client.isRunning {
            if let snapshot = try? await client.getInfo(),
               snapshot.walletState == .ready || snapshot.walletState == .syncing {
                try? await client.setHostForeground(true)
            }
            try? await resolveLifecycle()
        } else {
            await start()
            return
        }
        foregroundRestartPending = true
        await restartForForegroundIfSafe()
    }

    func switchNetwork(to selected: WalletNetwork) async {
        guard selected != network, canChangeNetwork else { return }
        network = selected
        defaults.set(selected.rawValue, forKey: "selectedNetwork")
        loadEndpointOverrides()
        sessionPassword = nil
        pendingMnemonic = nil
        isSessionLocked = false
        loadNetworkPreferences()
        await start()
    }

    func saveEndpointOverrides(operatorAddress: String, swapServerAddress: String, esploraURL: String) async {
        guard canChangeNetwork, !isSessionLocked, applicationIsActive() else { return }
        self.operatorAddress = operatorAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        self.swapServerAddress = swapServerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        self.esploraURL = esploraURL.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(operatorAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: endpointKey("operator"))
        defaults.set(swapServerAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: endpointKey("swap"))
        defaults.set(esploraURL.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: endpointKey("esplora"))
        await start()
    }

    func createWallet(mnemonic: [String] = [], showBackup: Bool = true, password suppliedPassword: String = "") async {
        guard phase == .needsSetup else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            try await beginStateCreatingCall()
            defer { endStateCreatingCall() }
            // Enable device authentication for new wallets when available.
            if defaults.object(forKey: "biometricUnlockEnabled") == nil,
               WalletAuthentication.available {
                let epoch = authenticationEpoch
                try await authenticate()
                try await finishForegroundAuthentication(epoch: epoch)
                defaults.set(true, forKey: "biometricUnlockEnabled")
                biometricUnlockEnabled = true
            }
            // Persist the exact password before creating the wallet. If the
            // daemon succeeds but its response is lost, a later unlock must
            // use this same durable secret rather than creating a new one.
            let account = keychainAccount
            let password = try suppliedPassword.isEmpty
                ? (KeychainStore.read(account: account) ?? KeychainStore.randomSecret())
                : Data(suppliedPassword.utf8)
            try KeychainStore.save(password, account: account)

            let result = try await client.createWallet(
                walletPassword: password,
                mnemonic: mnemonic
            )
            pendingMnemonic = showBackup ? result.mnemonic : nil
            defaults.set(!suppliedPassword.isEmpty, forKey: preferenceKey("userPassword"))
            if !suppliedPassword.isEmpty { try await savePasswordVerifier(password) }
            sessionPassword = password
            try await activateWallet()
        } catch {
            alertMessage = "Wallet setup didn’t finish. Your device keeps the same encrypted wallet key so it can safely resume: \(error.walletMessage)"
            await refreshLifecycleAfterAmbiguousSetup()
        }
    }

    func unlockWallet(password: String) async {
        guard canUnlockWallet, !password.isEmpty, stateCreatingCallCount == 0 else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await beginStateCreatingCall(requiresUnlock: false)
            defer { endStateCreatingCall() }
            alertMessage = nil
            let epoch = authenticationEpoch
            let secret = Data(password.utf8)
            let state = try await client.getInfo()
            if state.walletState == .locked {
                _ = try await client.unlockWallet(walletPassword: secret)
            } else if isSessionLocked && (state.walletState == .ready || state.walletState == .syncing) {
                // UI locking does not stop daemon-owned payments or rounds.
                // Legacy passwords remain an explicit foreground fallback.
                let account = keychainAccount + ".verifier"
                let matches = try await Task.detached {
                    guard let data = try KeychainStore.read(account: account) else { return false }
                    return try JSONDecoder().decode(CredentialVerifier.self, from: data).matches(secret)
                }.value
                guard matches else { throw WalletActionError(message: "Incorrect password.") }
            } else {
                try await resolveLifecycle()
                return
            }
            try await savePasswordVerifier(secret)
            try requireCurrentAuthentication(epoch: epoch)
            if biometricUnlockEnabled { defaults.set(true, forKey: "biometricUnlockEnabled") }
            try WalletAuthentication.migrate(secret, account: keychainAccount)
            defaults.set(true, forKey: preferenceKey("userPassword"))
            sessionPassword = secret
            isSessionLocked = false
            try await activateWallet()
        } catch {
            alertMessage = "Couldn’t unlock this wallet: \(error.walletMessage)"
        }
    }

    func acknowledgeSeedBackup() {
        guard !isSessionLocked, applicationIsActive() else { return }
        pendingMnemonic = nil
    }

    func refresh() async {
        do {
            let nextInfo = try await client.getInfo()
            info = nextInfo
            if nextInfo.walletState == .none || nextInfo.walletState == .locked {
                try await resolveLifecycle()
                return
            }
            phase = nextInfo.walletReady ? .ready : .syncing
            if applicationIsActive(), !isSessionLocked, !nextInfo.serverConnected {
                // Retry a failed initial resume without replacing the daemon
                // or discarding an accepted round/signing session.
                try? await client.setHostForeground(true)
            }

            if nextInfo.walletState == .ready {
                // Publish each independent snapshot as soon as it arrives. A
                // slow optional credit lookup must not hide newer Activity,
                // and a history error must not suppress a valid balance.
                async let balanceRefresh: Void = refreshBalanceSnapshot()
                async let activityRefresh: Void = refreshActivitySnapshot()
                _ = await (balanceRefresh, activityRefresh)
                await refreshMaintenanceState()
            }
        } catch {
            // A transient refresh failure does not mean the daemon stopped or
            // that a funds-moving operation failed. Keep the current state and
            // let the next observation reconcile it.
        }
    }

    func prepareSend(
        destination: String,
        amountSat: Int64,
        note: String,
        maxFeeSat: Int64,
        sweepAll: Bool = false
    ) async throws -> PrepareSendResult {
        try requireForegroundInteraction()
        if let work = receiptWindowWork { _ = try? await work.value }
        try requireForegroundInteraction()
        if destination.lowercased().hasPrefix("ln") {
            return try await client.prepareSend(
                invoice: destination,
                note: note,
                maxFeeSat: maxFeeSat,
                maxCreditSat: maxCreditSat,
                maxCreditTopupSat: maxCreditTopupSat
            )
        }
        return try await client.prepareSend(
            onchainAddress: destination,
            amountSat: amountSat,
            note: note,
            sweepAll: sweepAll
        )
    }

    func sendPrepared(_ quote: PrepareSendResult) async throws -> SendResult {
        guard pendingDispatch == nil else { throw WalletActionError(message: "Check the existing payment in Activity.") }
        try await beginStateCreatingCall()
        defer { endStateCreatingCall() }
        // Read the baseline before dispatch. An earlier failed payment may
        // reuse the same hash or input, but cannot resolve this new attempt.
        let snapshot = try await client.list(view: .activity, limit: 1_000)
        guard let baseline = snapshot.activity?.entries else {
            throw WalletActionError(message: "Couldn’t load Activity. Check the connection and try again.")
        }
        try requireForegroundInteraction()
        let pending = PendingDispatch(intentID: quote.sendIntentID, amountSat: quote.amountSat,
                                      paymentHash: quote.paymentHash, selectedOutpoints: quote.selectedOutpoints,
                                      existingEntryIDs: baseline.map(\.id), startedAt: Date(), destination: quote.destinationSummary)
        defaults.set(try JSONEncoder().encode(pending), forKey: preferenceKey("pendingDispatch"))
        pendingDispatch = pending
        do {
            let result = try await client.send(quote.sendIntentID)
            upsert(result.entry)
            clearPendingDispatch()
            await refresh()
            return result
        } catch {
            if (error as? WalletError)?.isSendRejectedBeforeDispatch == true {
                clearPendingDispatch()
            } else {
                pendingDispatch?.error = error.walletMessage
                persistPendingDispatch()
            }
            await refresh()
            throw error
        }
    }

    func receiveLightning(amountSat: Int64, memo: String) async throws -> ReceiveResult {
        try await beginStateCreatingCall()
        defer { endStateCreatingCall() }
        let existingEntryIDs = Set(activity.map(\.id))
        let receiptContext = WalletNotifications.shared.receiptCreationContext()

        do {
            let result = try await client.receiveLightning(
                amountSat: amountSat,
                memo: memo,
                timeoutSeconds: 20
            )
            upsert(result.entry)
            WalletNotifications.shared.enrollCreatedReceive(result, context: receiptContext)
            return result
        } catch {
            guard let walletError = error as? WalletError,
                  walletError.isReceiveOutcomeUncertain ||
                    walletError.isDeadlineExceeded else {
                throw error
            }

            // A request deadline or lifecycle cancellation can race durable
            // creation. Reconcile Activity and recover that exact invoice.
            // Never issue a second state-creating call automatically after an
            // uncertain result.
            await refreshActivitySnapshot()
            if let recovered = recoveredReceive(
                amountSat: amountSat,
                memo: memo,
                excluding: existingEntryIDs
            ) {
                return recovered
            }

            throw ReceiveCreationUncertainError()
        }
    }

    func newDepositAddress(amountHintSat: Int64) async throws -> DepositResult {
        try await beginStateCreatingCall()
        defer { endStateCreatingCall() }
        // Allocating an address does not mean funds are in flight. The daemon
        // deliberately does not persist Deposit's request-only Entry; it adds
        // the canonical deposit row once Esplora observes a UTXO. Keep the
        // address on the Receive screen and let List/Subscribe surface real
        // activity with the observed amount.
        return try await client.newDepositAddress(amountSatHint: amountHintSat)
    }

    private func resolveLifecycle() async throws {
        let snapshot = try await client.getInfo()
        info = snapshot
        switch snapshot.walletState {
        case .none:
            // Keychain survives reinstall; the daemon is the authority on
            // whether these credentials still belong to a wallet.
            try KeychainStore.delete(account: keychainAccount)
            try KeychainStore.delete(account: keychainAccount + ".verifier")
            try WalletAuthentication.delete(account: keychainAccount)
            sessionPassword = nil
            loadBiometricPreference()
            isSessionLocked = false
            if let pendingDispatch { unresolvedDispatches.append(pendingDispatch) }
            if let sweepOperation { unresolvedSweeps.append(sweepOperation) }
            persistUnresolvedChecks()
            clearPendingDispatch()
            refreshOperation = nil
            sweepOperation = nil
            defaults.removeObject(forKey: preferenceKey("refresh"))
            defaults.removeObject(forKey: preferenceKey("sweep"))
            phase = .needsSetup
        case .locked:
            if !hasPasswordFallback && !WalletAuthentication.contains(account: keychainAccount) {
                managedKeyUnavailable = try KeychainStore.read(account: keychainAccount) == nil
            } else {
                managedKeyUnavailable = false
            }
            if managedKeyUnavailable {
                isSessionLocked = true
                phase = .needsUnlock
            } else if biometricUnlockEnabled && sessionPassword == nil {
                isSessionLocked = true
                phase = .needsUnlock
            } else if let password = try sessionPassword ?? KeychainStore.read(account: keychainAccount) {
                do {
                    _ = try await client.unlockWallet(walletPassword: password)
                    try await activateWallet()
                } catch {
                    phase = .needsUnlock
                }
            } else {
                phase = .needsUnlock
            }
        case .ready, .syncing:
            if biometricUnlockEnabled && (sessionPassword == nil || isSessionLocked) {
                isSessionLocked = true
                phase = snapshot.walletReady ? .ready : .syncing
            } else {
                try await activateWallet()
            }
        case .unspecified:
            phase = .syncing
            beginMonitoring()
        }
    }

    private func activateWallet(revealAuthenticatedSession: Bool = false) async throws {
        let snapshot = try await client.getInfo()
        info = snapshot
        guard snapshot.walletState == .ready || snapshot.walletState == .syncing else {
            try await resolveLifecycle()
            return
        }
        phase = .syncing
        guard !isSessionLocked else { return }
        if !applicationIsActive() {
            // A transient system sheet must not abandon activation. A real
            // background transition is resumed by the normal scene handler.
            do { try await waitForForeground() } catch { return }
        }
        guard applicationIsActive(), !isSessionLocked else { return }
        if revealAuthenticatedSession {
            unlockStage = nil
            isWorking = false
        }
        // Local balance and activity do not depend on mailbox intake or the
        // recovery scan. Publish them while foreground connectivity resumes.
        async let balanceRefresh: Void = refreshBalanceSnapshot()
        async let activityRefresh: Void = refreshActivitySnapshot()
        try? await client.setHostForeground(true)
        _ = await (balanceRefresh, activityRefresh)
        if let current = try? await client.getInfo() {
            info = current
            phase = current.walletReady ? .ready : .syncing
        }
        beginMonitoring()
        WalletNotifications.shared.reconcile()
    }

    private func refreshLifecycleAfterAmbiguousSetup() async {
        guard let snapshot = try? await client.getInfo() else { return }
        info = snapshot
        switch snapshot.walletState {
        case .none: phase = .needsSetup
        case .locked: phase = .needsUnlock
        case .ready, .syncing:
            if biometricUnlockEnabled && sessionPassword == nil {
                isSessionLocked = true
                phase = .needsUnlock
            } else {
                try? await activateWallet()
            }
        case .unspecified: phase = .syncing
        }
    }

    private func beginMonitoring() {
        stopMonitoring()
        let currentGeneration = generation

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, currentGeneration == self.generation else { return }
                await self.refresh()
            }
        }

        let stream = client.activity(includeExisting: true)
        activityTask = Task { [weak self] in
            do {
                for try await entry in stream {
                    guard let self, currentGeneration == self.generation else { return }
                    self.upsert(entry)
                }
            } catch {
                // A later refresh reconciles the list. Stream termination is
                // expected when changing networks or stopping the daemon.
            }
        }
    }

    private func stopMonitoring() {
        refreshTask?.cancel()
        activityTask?.cancel()
        refreshTask = nil
        activityTask = nil
    }

    private func upsert(_ entry: Entry) {
        if let index = activity.firstIndex(where: { $0.id == entry.id }) {
            activity[index] = entry
        } else {
            activity.insert(entry, at: 0)
        }
    }

    private func recoveredReceive(
        amountSat: Int64,
        memo: String,
        excluding existingEntryIDs: Set<String>
    ) -> ReceiveResult? {
        guard let entry = activity.first(where: {
            !existingEntryIDs.contains($0.id) &&
                $0.kind == "receive" &&
                $0.amountSat == amountSat &&
                $0.note == memo &&
                $0.request?.type == "lightning" &&
                !($0.request?.lightningInvoice.isEmpty ?? true)
        }), let invoice = entry.request?.lightningInvoice else {
            return nil
        }

        return ReceiveResult(invoice: invoice, entry: entry)
    }

    private func refreshBalanceSnapshot() async {
        guard let snapshot = try? await client.balance() else { return }
        balance = snapshot
    }

    private func refreshActivitySnapshot() async {
        let checkedIntent = stateCreatingCallCount == 0 ? pendingDispatch?.intentID : nil
        guard let result = try? await client.list(
            view: .activity,
            limit: 100
        ), let entries = result.activity?.entries else {
            return
        }

        // List is the daemon's authoritative, already-deduplicated activity
        // view in most-recent-first order. Replacing the snapshot also removes
        // terminal or request-only rows that are no longer wallet activity.
        activity = entries
        activityLoaded = true
        if let pending = pendingDispatch,
           entries.contains(where: pending.matches) {
            clearPendingDispatch()
        } else if let checkedIntent, checkedIntent == pendingDispatch?.intentID,
                  stateCreatingCallCount == 0, (pendingDispatch?.checks ?? 0) < 2 {
            pendingDispatch?.checks = (pendingDispatch?.checks ?? 0) + 1
            persistPendingDispatch()
        }
        let unresolvedCount = unresolvedDispatches.count
        unresolvedDispatches.removeAll { attempt in entries.contains(where: attempt.matches) }
        if unresolvedDispatches.count != unresolvedCount { persistUnresolvedChecks() }
    }

    /// UI authentication is separate from native unlock. Recheck after waiting
    /// for a window so a queued button action cannot outlive the UI session.
    private func requireForegroundInteraction(requiresUnlock: Bool = true) throws {
        guard applicationIsActive(), !requiresUnlock || !isSessionLocked else {
            throw WalletActionError(message: "Unlock Wavelength to continue.")
        }
    }

    private func finishForegroundAuthentication(epoch: Int) async throws {
        try await waitForForeground()
        try requireCurrentAuthentication(epoch: epoch)
    }

    private func requireCurrentAuthentication(epoch: Int) throws {
        guard epoch == authenticationEpoch else { throw LAError(.systemCancel) }
        try requireForegroundInteraction(requiresUnlock: false)
    }

    private func beginStateCreatingCall(requiresUnlock: Bool = true) async throws {
        try requireForegroundInteraction(requiresUnlock: requiresUnlock)
        if let preparation = backgroundPreparation { _ = await preparation.value }
        if let work = receiptWindowWork { _ = try? await work.value }
        try requireForegroundInteraction(requiresUnlock: requiresUnlock)
        stateCreatingCallCount += 1
        if receiptBackgroundRequested {
            receiptBackgroundRequested = false
            try? await client.setHostForeground(true)
        }
    }

    private func endStateCreatingCall() {
        stateCreatingCallCount = max(0, stateCreatingCallCount - 1)
        if stateCreatingCallCount == 0, receiptBackgroundRequested {
            Task { await setReceiptBackgroundMode(enabled: true) }
        }
        guard stateCreatingCallCount == 0, foregroundRestartPending else {
            return
        }

        Task { [weak self] in
            await self?.restartForForegroundIfSafe()
        }
    }

    private func restartForForegroundIfSafe() async {
        guard foregroundRestartPending, stateCreatingCallCount == 0, !isSessionLocked, applicationIsActive() else {
            return
        }
        foregroundRestartPending = false
        // A deferred foreground return may follow a paused maintenance window.
        // Resume intake before using connection health to decide on teardown.
        try? await client.setHostForeground(true)
        // A healthy daemon can keep an accepted round alive across a short
        // background transition. Restart only when the transport needs it;
        // unconditional teardown discards an assembling refresh round.
        if let snapshot = try? await client.getInfo(),
           snapshot.walletState == .ready || snapshot.walletState == .syncing,
           snapshot.serverConnected {
            await refresh()
            beginMonitoring()
            return
        }
        await start()
    }

    func lockForBackground() {
        authenticationEpoch += 1
        stopMonitoring()
        guard biometricUnlockEnabled else { return }
        sessionPassword = nil
        isSessionLocked = true
    }

    private func unlockNativeWallet(secret: Data) async throws -> Info {
        let state = try await client.getInfo()
        if state.walletState == .locked {
            _ = try await client.unlockWallet(walletPassword: secret)
        }
        return state
    }

    func unlockWithBiometrics() async {
        guard canUnlockWallet, biometricUnlockEnabled, !isWorking, stateCreatingCallCount == 0 else { return }
        isWorking = true
        unlockStage = .authenticating
        defer { isWorking = false; unlockStage = nil }
        let account = keychainAccount
        do {
            try await beginStateCreatingCall(requiresUnlock: false)
            defer { endStateCreatingCall() }
            let epoch = authenticationEpoch
            let secret: Data
            if WalletAuthentication.contains(account: account) {
                // Legacy access control authenticates this read. Do not erase
                // that copy until the actual wallet accepts the credential.
                secret = try await Task.detached { try WalletAuthentication.read(account: account) }.value
            } else {
                try await authenticate()
                guard let managed = try KeychainStore.read(account: account) else {
                    throw WalletActionError(message: "Wallet key unavailable on this iPhone.")
                }
                secret = managed
            }
            unlockStage = .opening
            // Authentication has succeeded, so native unlock may overlap the
            // system prompt's dismissal. The UI remains locked, and this
            // structured child is joined before lifecycle ownership is released.
            async let nativeState = unlockNativeWallet(secret: secret)
            try await finishForegroundAuthentication(epoch: epoch)
            let state = try await nativeState
            if state.walletState == .none { try await resolveLifecycle(); return }
            if hasPasswordFallback { try await savePasswordVerifier(secret) }
            try requireCurrentAuthentication(epoch: epoch)
            try WalletAuthentication.migrate(secret, account: account)
            defaults.set(true, forKey: "biometricUnlockEnabled")
            sessionPassword = secret
            isSessionLocked = false
            try await activateWallet(revealAuthenticatedSession: true)
            await restartForForegroundIfSafe()
        } catch {
            sessionPassword = nil
            if (error as? KeychainError)?.status != errSecUserCanceled &&
                (error as? KeychainError)?.status != errSecAuthFailed &&
                (error as? LAError)?.code != .userCancel &&
                (error as? LAError)?.code != .systemCancel {
                alertMessage = error.walletMessage
            }
        }
    }

    func setBiometricUnlock(_ enabled: Bool) async {
        guard enabled != biometricUnlockEnabled, !isWorking, !isSessionLocked else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try requireForegroundInteraction()
            let epoch = authenticationEpoch
            let accounts = walletKeychainAccounts.filter { WalletAuthentication.contains(account: $0) }
            if accounts.isEmpty {
                try await authenticate()
            } else {
                let secrets = try await Task.detached { try WalletAuthentication.read(accounts: accounts) }.value
                try await finishForegroundAuthentication(epoch: epoch)
                for (account, secret) in secrets { try WalletAuthentication.migrate(secret, account: account) }
            }
            try await finishForegroundAuthentication(epoch: epoch)
            defaults.set(enabled, forKey: "biometricUnlockEnabled")
        } catch { alertMessage = error.walletMessage }
        loadBiometricPreference()
    }

    private var walletKeychainAccounts: [String] {
        WalletNetwork.allCases.map { keychainAccount(for: $0) }
    }

    /// A legacy protected wallet opts the installation into the shared policy.
    /// Keep actual credentials isolated by network; never reuse their passwords.
    private func loadBiometricPreference() {
        biometricUnlockEnabled = defaults.bool(forKey: "biometricUnlockEnabled") ||
            walletKeychainAccounts.contains { WalletAuthentication.contains(account: $0) }
    }

    private func savePasswordVerifier(_ secret: Data) async throws {
        let account = keychainAccount + ".verifier"
        try await Task.detached {
            let verifier = try CredentialVerifier(secret: secret)
            try KeychainStore.save(JSONEncoder().encode(verifier), account: account)
        }.value
    }

    func saveCreditLimits(use: UInt64, topup: UInt64) {
        guard !isSessionLocked, applicationIsActive() else { return }
        maxCreditSat = use
        maxCreditTopupSat = topup
        defaults.set(String(use), forKey: preferenceKey("maxCredit"))
        defaults.set(String(topup), forKey: preferenceKey("maxCreditTopup"))
    }

    func inventory() async throws -> [WalletVTXO] {
        try requireForegroundInteraction()
        return try await client.list(view: .vtxos, limit: 1_000).vtxos?.vtxos ?? []
    }

    func recoveryFunds() async throws -> [WalletVTXO] {
        try requireForegroundInteraction()
        return try await client.recoveryInventory().vtxos
    }

    func exitPlan(outpoint: String) async throws -> ExitPlan {
        try requireForegroundInteraction()
        return try await client.getExitPlan(outpoints: [outpoint])
    }

    func exitFunds(outpoint: String, destination: String, unilateral: Bool) async throws -> ExitResult {
        try await beginStateCreatingCall()
        defer { endStateCreatingCall() }
        let result = try await client.exit(outpoint: outpoint, destination: unilateral ? "" : destination,
            forceUnrollAck: unilateral ? "I_KNOW_WHAT_I_AM_DOING" : "")
        await refresh()
        return result
    }

    func recoveryStatus(outpoint: String) async throws -> ExitStatusResult {
        try requireForegroundInteraction()
        return try await client.exitStatus(outpoint: outpoint)
    }

    func previewSweep(destination: String) async throws -> SweepPreview {
        try requireForegroundInteraction()
        return try await client.sweepWallet(destination: destination, broadcast: false)
    }

    func sweep(destination: String, preview: SweepPreview) async throws {
        guard sweepOperation == nil, preview.canBroadcast, preview.feeRateSatPerVByte > 0 else {
            throw WalletActionError(message: "Check the existing transfer before sending again.")
        }
        try await beginStateCreatingCall()
        defer { endStateCreatingCall() }
        sweepOperation = SweepOperation(destination: destination, amountSat: preview.netAmountSat,
                                        feeRate: preview.feeRateSatPerVByte, startedAt: Date())
        persistSweep()
        do {
            let result = try await client.sweepWallet(destination: destination, broadcast: true,
                                                     feeRateSatPerVByte: preview.feeRateSatPerVByte)
            if !result.txid.isEmpty {
                sweepOperation?.amountSat = result.netAmountSat
                sweepOperation?.txid = result.txid
                sweepOperation?.status = "In progress"
            } else if result.totalInputSat == 0 {
                // The pinned daemon returns zero inputs before building or
                // publishing anything. CanBroadcast alone is insufficient:
                // it is also false on errors after submission was attempted.
                sweepOperation = nil
                defaults.removeObject(forKey: preferenceKey("sweep"))
                throw WalletActionError(message: result.failureReason)
            } else {
                sweepOperation?.status = "Action needed"
                sweepOperation?.error = result.failureReason
            }
            persistSweep()
            await refresh()
        } catch {
            sweepOperation?.error = error.walletMessage
            persistSweep()
            throw error
        }
    }

    func finishSweep() {
        guard !isSessionLocked, applicationIsActive() else { return }
        // A returned transaction id acknowledges this broadcast. Unknown
        // attempts stay blocked; a known receipt can be explicitly dismissed
        // before the user prepares a separate transfer.
        guard let operation = sweepOperation, !operation.txid.isEmpty else { return }
        sweepOperation = nil
        defaults.removeObject(forKey: preferenceKey("sweep"))
    }

    private func persistSweep() {
        defaults.set(try? JSONEncoder().encode(sweepOperation), forKey: preferenceKey("sweep"))
    }

    func exportRecovery(outpoints: [String]) async throws -> Data {
        try requireForegroundInteraction()
        return try await client.exportRecovery(outpoints: outpoints)
    }

    func previewRefresh() async throws -> RefreshResult {
        try requireForegroundInteraction()
        return try await client.refreshFunds(dryRun: true)
    }

    func startRefresh(outpoints: [String], amountSat: Int64) async throws {
        guard refreshOperation == nil || refreshOperation?.status == "Complete" else {
            throw WalletActionError(message: "Check the existing refresh before starting another.")
        }
        try await beginStateCreatingCall()
        defer { endStateCreatingCall() }
        refreshOperation = RefreshOperation(outpoints: outpoints, amountSat: amountSat, status: "Checking status")
        persistRefresh()
        do {
            let result = try await client.refreshFunds(outpoints: outpoints, dryRun: false)
            let queued = result.queuedOutpoints ?? []
            refreshOperation = RefreshOperation(outpoints: queued.isEmpty ? outpoints : queued, amountSat: amountSat,
                                               status: queued.isEmpty ? "Action needed" : "In progress")
            persistRefresh()
            await refresh()
        } catch {
            // A failed round join may already have reserved these inputs.
            // Preserve the operation instead of silently queuing another.
            refreshOperation?.status = "Action needed"
            persistRefresh()
            throw error
        }
    }

    func clearCompletedRefresh() {
        guard !isSessionLocked, applicationIsActive() else { return }
        guard refreshOperation?.status == "Complete" || refreshOperation?.canRetry == true else { return }
        refreshOperation = nil
        defaults.removeObject(forKey: preferenceKey("refresh"))
    }

    var recoverableAmountSat: Int64 {
        let height = info?.blockHeight ?? 0
        return recoveryInventory.filter { $0.status == "expired" ||
            ($0.status == "live" && ($0.batchExpiry ?? 0) > 0 && ($0.batchExpiry ?? 0) <= height) }
            .reduce(0) { $0 + $1.amountSat }
    }

    private func refreshMaintenanceState() async {
        if let inventory = try? await client.recoveryInventory() { recoveryInventory = inventory.vtxos }
        let checkedSweep = stateCreatingCallCount == 0 ? sweepOperation?.id : nil
        if let history = try? await client.list(view: .onchain, limit: 100), let transactions = history.onchain?.txs {
            onchainHistory = transactions
            if let checkedSweep, checkedSweep == sweepOperation?.id,
               stateCreatingCallCount == 0, (sweepOperation?.checks ?? 0) < 2 {
                sweepOperation?.checks = (sweepOperation?.checks ?? 0) + 1
                persistSweep()
            }
        }
        if let operation = sweepOperation, !operation.txid.isEmpty,
           onchainHistory.contains(where: { $0.txid == operation.txid && ($0.status == "confirmed" || $0.status == "complete") }) {
            sweepOperation?.status = "Complete"
            persistSweep()
        }

        if let summary = try? await client.exitSummary() { recoveryJobs = summary.exits ?? [] }
        if let operation = refreshOperation, operation.status != "Complete",
           let observation = try? await client.observeRefresh(outpoints: operation.outpoints) {
            if observation.complete {
                refreshOperation?.status = "Complete"
            } else if observation.retryAllowed == true {
                refreshOperation?.status = "Action needed"
                refreshOperation?.canRetry = true
            }
            persistRefresh()
        }
    }

    private func persistRefresh() {
        defaults.set(try? JSONEncoder().encode(refreshOperation), forKey: preferenceKey("refresh"))
    }

    private func clearPendingDispatch() {
        pendingDispatch = nil
        defaults.removeObject(forKey: preferenceKey("pendingDispatch"))
    }

    private func persistPendingDispatch() {
        defaults.set(try? JSONEncoder().encode(pendingDispatch), forKey: preferenceKey("pendingDispatch"))
    }

    /// This is an explicit acknowledgment, not proof the first attempt failed.
    /// Keep its evidence and never resubmit its intent or its sweep automatically.
    func startSeparatePaymentAfterChecking() {
        guard !isSessionLocked, applicationIsActive() else { return }
        guard stateCreatingCallCount == 0, let pending = pendingDispatch,
              pending.canStartSeparatePayment else { return }
        unresolvedDispatches.append(pending)
        persistUnresolvedChecks()
        clearPendingDispatch()
    }

    func startSeparateSweepAfterChecking() {
        guard !isSessionLocked, applicationIsActive() else { return }
        guard stateCreatingCallCount == 0, let operation = sweepOperation,
              operation.canStartSeparateTransfer else { return }
        unresolvedSweeps.append(operation)
        persistUnresolvedChecks()
        sweepOperation = nil
        defaults.removeObject(forKey: preferenceKey("sweep"))
    }

    private func persistUnresolvedChecks() {
        defaults.set(try? JSONEncoder().encode(unresolvedDispatches), forKey: preferenceKey("unresolvedDispatches"))
        defaults.set(try? JSONEncoder().encode(unresolvedSweeps), forKey: preferenceKey("unresolvedSweeps"))
    }

    private func preferenceKey(_ name: String) -> String { "\(network.rawValue).\(name)" }

    private func loadNetworkPreferences() {
        loadBiometricPreference()
        isSessionLocked = biometricUnlockEnabled
        maxCreditSat = UInt64(defaults.string(forKey: preferenceKey("maxCredit")) ?? "") ?? 10_000
        maxCreditTopupSat = UInt64(defaults.string(forKey: preferenceKey("maxCreditTopup")) ?? "") ?? 10_000
        pendingDispatch = defaults.data(forKey: preferenceKey("pendingDispatch")).flatMap {
            try? JSONDecoder().decode(PendingDispatch.self, from: $0)
        }
        refreshOperation = defaults.data(forKey: preferenceKey("refresh")).flatMap {
            try? JSONDecoder().decode(RefreshOperation.self, from: $0)
        }
        sweepOperation = defaults.data(forKey: preferenceKey("sweep")).flatMap {
            try? JSONDecoder().decode(SweepOperation.self, from: $0)
        }
        unresolvedDispatches = defaults.data(forKey: preferenceKey("unresolvedDispatches")).flatMap {
            try? JSONDecoder().decode([PendingDispatch].self, from: $0)
        } ?? []
        unresolvedSweeps = defaults.data(forKey: preferenceKey("unresolvedSweeps")).flatMap {
            try? JSONDecoder().decode([SweepOperation].self, from: $0)
        } ?? []
        recoveryJobs = []
        recoveryInventory = []
        onchainHistory = []
    }

    var notificationGeneration: Int { generation }
    var notificationKnownIdentity: String? { info?.identityPubKey }

    /// Reads only a device-managed credential. Legacy biometric items require
    /// one foreground migration; a background launch never prompts or creates a wallet.
    /// This task retains lifecycle ownership even when the OS callback expires.
    func prepareBackgroundWallet(windowID: String, lease: ReceiptFetchLease,
                                 expectedIdentity: String? = nil) async -> Bool {
        guard !lease.expired, !applicationIsActive(), !isWorking,
              phase != .starting, stateCreatingCallCount == 0,
              backgroundPreparation == nil else { return false }
        receiptBackgroundRequested = true
        backgroundPreparationID = windowID
        stateCreatingCallCount += 1
        stopMonitoring()
        if biometricUnlockEnabled { isSessionLocked = true; sessionPassword = nil }
        let work = Task {
            defer {
                self.backgroundPreparation = nil
                self.backgroundPreparationID = nil
                self.backgroundStartedRuntime = false
                self.stateCreatingCallCount -= 1
            }
            return await self.prepareBackgroundRuntime(lease: lease, expectedIdentity: expectedIdentity)
        }
        backgroundPreparation = work
        return await work.value
    }

    private func prepareBackgroundRuntime(lease: ReceiptFetchLease, expectedIdentity: String?) async -> Bool {
        func permitted() -> Bool { !lease.expired && receiptBackgroundRequested && !applicationIsActive() }
        do {
            guard permitted() else { return false }
            if !(await client.isRunning) {
                // Read before creating/opening any database. Before first device
                // unlock, or with only a legacy key, this opportunity does nothing.
                guard let secret = try KeychainStore.read(account: keychainAccount), permitted() else { return false }
                // Re-wait a previous attempt's cleanup even when isRunning is
                // false. A pending stop must prevent this start, not overlap it.
                try await stopClient()
                guard permitted() else { return false }
                phase = .starting
                backgroundStartedRuntime = true
                try await startClient(walletConfig())
                guard permitted() else { throw CancellationError() }
                let snapshot = try await client.getInfo()
                guard snapshot.walletState != .none else { throw CancellationError() }
                if snapshot.walletState == .locked {
                    _ = try await client.unlockWallet(walletPassword: secret)
                }
            } else {
                let snapshot = try await client.getInfo()
                if snapshot.walletState == .locked {
                    guard let secret = try KeychainStore.read(account: keychainAccount), permitted() else { return false }
                    _ = try await client.unlockWallet(walletPassword: secret)
                }
            }
            // The startup config already disables automatic ingress. This also
            // joins any earlier warm foreground owner before a bounded window.
            try await client.setHostForeground(false)
            let snapshot = try await client.getInfo()
            info = snapshot
            guard snapshot.walletState == .ready || snapshot.walletState == .syncing else { throw CancellationError() }
            phase = snapshot.walletReady ? .ready : .syncing
            guard permitted(), expectedIdentity == nil || expectedIdentity == snapshot.identityPubKey else { return false }
            return true
        } catch {
            // Stop only a runtime booted by this attempt. Never tear down a
            // retained foreground payment because a background opportunity failed.
            if backgroundStartedRuntime {
                try? await stopClient()
                phase = .idle
                info = nil
            }
            return false
        }
    }

    func setReceiptBackgroundMode(enabled: Bool) async {
        guard enabled else { receiptBackgroundRequested = false; return }
        guard !applicationIsActive() else { return }
        receiptBackgroundRequested = true
        guard stateCreatingCallCount == 0, phase.isWalletAvailable else { return }
        try? await client.setHostForeground(false)
        if !receiptBackgroundRequested { try? await client.setHostForeground(true) }
    }

    func runReceiptWindow(_ request: ReceiptWindowRequest, identity: String) async throws -> ReceiptWindowResult {
        guard notificationRuntimeIdentity == identity, receiptBackgroundRequested, !applicationIsActive(),
              stateCreatingCallCount == 0, receiptWindowWork == nil else { throw CancellationError() }
        stateCreatingCallCount += 1
        let work = Task { try await client.runReceiptWindow(request, timeoutSeconds: 15) }
        receiptWindowWork = work
        defer {
            receiptWindowWork = nil
            endStateCreatingCall()
        }
        return try await work.value
    }

    /// Advances the prepared native runtime while preserving the UI lock.
    func runMaintenanceWindow(_ id: String) async throws -> ReceiptWindowResult {
        guard phase.isWalletAvailable, notificationKnownIdentity != nil,
              receiptBackgroundRequested, !applicationIsActive(),
              stateCreatingCallCount == 0, receiptWindowWork == nil else { throw CancellationError() }
        stateCreatingCallCount += 1
        let work = Task { try await client.runMaintenanceWindow(id, timeoutSeconds: 15) }
        receiptWindowWork = work
        defer {
            receiptWindowWork = nil
            endStateCreatingCall()
        }
        return try await work.value
    }

    func cancelReceiptWindow(_ id: String) async {
        if backgroundPreparationID == id {
            receiptBackgroundRequested = false
            // Stop cancels unpublished startup too. The preparation task still
            // owns cleanup until it returns; foreground startup waits for it.
            if backgroundStartedRuntime { try? await stopClient() }
            return
        }
        try? await client.cancelReceiptWindow(id)
    }

    var notificationRuntimeIdentity: String? {
        guard phase.isWalletAvailable, let identity = info?.identityPubKey, !identity.isEmpty else { return nil }
        return identity
    }

    var notificationConfiguration: NotificationRelayConfiguration? {
        guard operatorAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              swapServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .bundled(network: network)
    }

    var notificationIdentity: String? {
        guard phase.isWalletAvailable, !isSessionLocked,
              let identity = info?.identityPubKey, !identity.isEmpty else { return nil }
        return identity
    }

    /// Source registration owns admission until the signed RPC returns. Network
    /// switching cannot replace the native singleton during this operation.
    func bindNotification(_ grant: NotificationRelayGrant, source: NotificationSource,
                          configuration: NotificationRelayConfiguration, network: String,
                          identity: String) async throws -> NotificationFeedGrantResult {
        guard self.network.rawValue == network, notificationIdentity == identity,
              notificationConfiguration == configuration else { throw CancellationError() }
        let offer = try grant.offer(for: source)
        let currentGeneration = generation
        try await beginStateCreatingCall()
        defer { endStateCreatingCall() }
        let result = try await client.setNotificationFeedGrant(.register(
            source: source, grantID: offer.grantId, subscriberPubkey: offer.subscriberPubkey,
            subscriberSignature: offer.subscriberSignature, eventClasses: offer.eventClasses,
            expiresAtUnix: offer.expiresAtUnix))
        guard currentGeneration == generation, result.grantID == offer.grantId,
              result.expiresAtUnix > Int64(Date().timeIntervalSince1970),
              result.expiresAtUnix <= offer.expiresAtUnix else { throw NotificationRelayError.invalidResponse }
        return result
    }

    func removeNotification(_ subscription: String, source: NotificationSource,
                            network: String, identity: String) async throws {
        guard self.network.rawValue == network, notificationIdentity == identity else { throw CancellationError() }
        try await beginStateCreatingCall()
        defer { endStateCreatingCall() }
        _ = try await client.setNotificationFeedGrant(.remove(source: source, grantID: subscription))
    }

    private func walletConfig() throws -> WalletConfig {
        let support = try dataRoot ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support
            .appendingPathComponent("Wavelength", isDirectory: true)
            .appendingPathComponent(network.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: directory.path)
        var config: WalletConfig = .network(
            network,
            dataDir: directory.path,
            esploraURL: esploraURL.trimmingCharacters(in: .whitespacesAndNewlines),
            operatorAddress: operatorAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            swapServerAddress: swapServerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        config.durableRoundRuntime = true
        config.hostDrivenIngress = true
        config.swapNotificationIssuer = notificationConfiguration?.swapIssuer
        return config
    }

    private var keychainAccount: String { keychainAccount(for: network) }

    private func keychainAccount(for network: WalletNetwork) -> String {
        (dataRoot.map { $0.lastPathComponent + "." } ?? "") + "wallet-password-\(network.rawValue)"
    }

    private func endpointKey(_ endpoint: String) -> String {
        "\(network.rawValue).\(endpoint)Address"
    }

    private func customEsploraResourceURL(kind: String, identifier: String) -> URL? {
        let value = esploraURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, var base = URL(string: value) else { return nil }
        // Hosted Esplora deployments such as mempool.space and
        // blockstream.info expose JSON below /api but their human-readable
        // transaction/address pages live one level above it.
        if base.lastPathComponent == "api" {
            base.deleteLastPathComponent()
        }
        return base.appendingPathComponent(kind).appendingPathComponent(identifier)
    }

    private func loadEndpointOverrides() {
        operatorAddress = defaults.string(forKey: endpointKey("operator")) ?? ""
        swapServerAddress = defaults.string(forKey: endpointKey("swap")) ?? ""
        esploraURL = defaults.string(forKey: endpointKey("esplora")) ?? ""
    }
}
