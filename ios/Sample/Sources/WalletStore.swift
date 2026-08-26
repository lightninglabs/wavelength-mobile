import Combine
import Foundation
import WalletKit

private struct ReceiveCreationUncertainError: LocalizedError {
    var errorDescription: String? {
        "The receive request ended before Wavelength could confirm the result. Wavelength couldn’t find a newly created invoice in Activity. Check Activity before trying again."
    }
}

@MainActor
final class WalletStore: ObservableObject {
    @Published private(set) var phase: WalletPhase = .idle
    @Published private(set) var info: Info?
    @Published private(set) var balance: Balance?
    @Published private(set) var activity: [Entry] = []
    @Published private(set) var isWorking = false
    @Published var pendingMnemonic: [String]?
    @Published var alertMessage: String?

    @Published private(set) var network: WalletNetwork
    @Published var operatorAddress: String
    @Published var swapServerAddress: String
    @Published var esploraURL: String

    private let client = WalletClient()
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var generation = 0
    private var stateCreatingCallCount = 0
    private var foregroundRestartPending = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        #if DEBUG
        if debugRegtest {
            let environment = ProcessInfo.processInfo.environment
            operatorAddress = environment["WAVELENGTH_OPERATOR_ADDRESS"] ?? operatorAddress
            swapServerAddress = environment["WAVELENGTH_SWAP_ADDRESS"] ?? swapServerAddress
            esploraURL = environment["WAVELENGTH_ESPLORA_URL"] ?? esploraURL
        }
        #endif
    }

    var isReady: Bool { phase == .ready }
    var isSyncing: Bool { phase == .syncing }
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

    /// Mainnet deliberately has no built-in public Ark service. Esplora can
    /// sync the backing wallet by itself, but boarding-address construction
    /// still requires operator terms.
    var operatorAvailable: Bool {
        if network == .mainnet || network == .regtest {
            return !operatorAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    /// Lightning receive/send additionally requires the swap service.
    var offchainAvailable: Bool {
        if network == .mainnet || network == .regtest {
            return operatorAvailable &&
                !swapServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    func start() async {
        generation += 1
        let currentGeneration = generation
        stopMonitoring()
        phase = .starting
        info = nil
        balance = nil
        activity = []

        do {
            if await client.isRunning {
                try await client.stop()
            }
            let config = try walletConfig()
            try await client.start(config)
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
        foregroundRestartPending = true
        await restartForForegroundIfSafe()
    }

    func switchNetwork(to selected: WalletNetwork) async {
        guard selected != network else { return }
        network = selected
        defaults.set(selected.rawValue, forKey: "selectedNetwork")
        loadEndpointOverrides()
        await start()
    }

    func saveEndpointOverrides() async {
        defaults.set(operatorAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: endpointKey("operator"))
        defaults.set(swapServerAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: endpointKey("swap"))
        defaults.set(esploraURL.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: endpointKey("esplora"))
        await start()
    }

    func createWallet(mnemonic: [String] = [], showBackup: Bool = true) async {
        guard phase == .needsSetup else { return }
        beginStateCreatingCall()
        defer { endStateCreatingCall() }
        isWorking = true
        defer { isWorking = false }

        do {
            // Persist the exact password before creating the wallet. If the
            // daemon succeeds but its response is lost, a later unlock must
            // use this same durable secret rather than creating a new one.
            let account = keychainAccount
            let password = try KeychainStore.read(account: account) ?? KeychainStore.randomSecret()
            try KeychainStore.save(password, account: account)

            let result = try await client.createWallet(
                walletPassword: password,
                mnemonic: mnemonic
            )
            pendingMnemonic = showBackup ? result.mnemonic : nil
            try await activateWallet()
        } catch {
            alertMessage = "Wallet setup didn’t finish. Your device keeps the same encrypted wallet key so it can safely resume: \(error.walletMessage)"
            await refreshLifecycleAfterAmbiguousSetup()
        }
    }

    func unlockWallet(password: String) async {
        guard phase == .needsUnlock, !password.isEmpty else { return }
        beginStateCreatingCall()
        defer { endStateCreatingCall() }
        isWorking = true
        defer { isWorking = false }
        do {
            let secret = Data(password.utf8)
            _ = try await client.unlockWallet(walletPassword: secret)
            try KeychainStore.save(secret, account: keychainAccount)
            try await activateWallet()
        } catch {
            alertMessage = "Couldn’t unlock this wallet: \(error.walletMessage)"
        }
    }

    func acknowledgeSeedBackup() {
        pendingMnemonic = nil
    }

    func refresh() async {
        do {
            let nextInfo = try await client.getInfo()
            info = nextInfo
            phase = nextInfo.walletReady ? .ready : .syncing

            if nextInfo.walletState == .ready {
                // Publish each independent snapshot as soon as it arrives. A
                // slow optional credit lookup must not hide newer Activity,
                // and a history error must not suppress a valid balance.
                async let balanceRefresh: Void = refreshBalanceSnapshot()
                async let activityRefresh: Void = refreshActivitySnapshot()
                _ = await (balanceRefresh, activityRefresh)
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
        maxFeeSat: Int64
    ) async throws -> PrepareSendResult {
        if destination.lowercased().hasPrefix("ln") {
            return try await client.prepareSend(
                invoice: destination,
                note: note,
                maxFeeSat: maxFeeSat
            )
        }
        return try await client.prepareSend(
            onchainAddress: destination,
            amountSat: amountSat,
            note: note
        )
    }

    func sendPrepared(intentID: String) async throws -> SendResult {
        beginStateCreatingCall()
        defer { endStateCreatingCall() }
        let result = try await client.send(intentID)
        upsert(result.entry)
        await refresh()
        return result
    }

    func receiveLightning(amountSat: Int64, memo: String) async throws -> ReceiveResult {
        beginStateCreatingCall()
        defer { endStateCreatingCall() }
        let existingEntryIDs = Set(activity.map(\.id))

        do {
            let result = try await client.receiveLightning(
                amountSat: amountSat,
                memo: memo,
                timeoutSeconds: 20
            )
            upsert(result.entry)
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
        beginStateCreatingCall()
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
            phase = .needsSetup
        case .locked:
            if let password = try KeychainStore.read(account: keychainAccount) {
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
            try await activateWallet()
        case .unspecified:
            phase = .syncing
            beginMonitoring()
        }
    }

    private func activateWallet() async throws {
        let snapshot = try await client.getInfo()
        info = snapshot
        phase = snapshot.walletReady ? .ready : .syncing
        await refresh()
        beginMonitoring()
    }

    private func refreshLifecycleAfterAmbiguousSetup() async {
        guard let snapshot = try? await client.getInfo() else { return }
        info = snapshot
        switch snapshot.walletState {
        case .none: phase = .needsSetup
        case .locked: phase = .needsUnlock
        case .ready, .syncing:
            try? await activateWallet()
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
    }

    private func beginStateCreatingCall() {
        stateCreatingCallCount += 1
    }

    private func endStateCreatingCall() {
        stateCreatingCallCount = max(0, stateCreatingCallCount - 1)
        guard stateCreatingCallCount == 0, foregroundRestartPending else {
            return
        }

        Task { [weak self] in
            await self?.restartForForegroundIfSafe()
        }
    }

    private func restartForForegroundIfSafe() async {
        guard foregroundRestartPending, stateCreatingCallCount == 0 else {
            return
        }
        foregroundRestartPending = false
        await start()
    }

    private func walletConfig() throws -> WalletConfig {
        let support = try FileManager.default.url(
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
        return .network(
            network,
            dataDir: directory.path,
            esploraURL: esploraURL.trimmingCharacters(in: .whitespacesAndNewlines),
            operatorAddress: operatorAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            swapServerAddress: swapServerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var keychainAccount: String { "wallet-password-\(network.rawValue)" }

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
