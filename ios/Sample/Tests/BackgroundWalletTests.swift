import XCTest
import UIKit
import LocalAuthentication
@testable import WalletKit
@testable import Wavelength

@MainActor
final class BackgroundWalletTests: XCTestCase {
    func testUnavailableCredentialAndExpiredWakeDoNotStartWallet() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let client = WalletClient()
        let store = fixture.store(client, active: { false })
        let expired = ReceiptFetchLease { _ in }
        expired.expire()
        let expiredReady = await store.prepareBackgroundWallet(windowID: "expired", lease: expired)
        XCTAssertFalse(expiredReady)
        let missingReady = await store.prepareBackgroundWallet(windowID: "missing", lease: ReceiptFetchLease { _ in })
        XCTAssertFalse(missingReady)
        let running = await client.isRunning
        XCTAssertFalse(running)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testLockedSessionRejectsDispatchAndExportBeforeNativeAccess() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: "biometricUnlockEnabled")
        let store = fixture.store(WalletClient(), active: { true })
        XCTAssertTrue(store.isSessionLocked)
        let quote = try invalidQuote()
        for action in [
            { _ = try await store.sendPrepared(quote) },
            { _ = try await store.exportRecovery(outpoints: []) },
            { _ = try await store.receiveLightning(amountSat: 10, memo: "must not create") },
            { _ = try await store.newDepositAddress(amountHintSat: 10) },
        ] {
            do { try await action(); XCTFail("Locked call reached the native API") }
            catch { XCTAssertEqual(error.localizedDescription, "Unlock Wavelength to continue.") }
        }
        XCTAssertNil(store.pendingDispatch)
        await store.setBiometricUnlock(false)
        XCTAssertTrue(store.biometricUnlockEnabled)
    }

    /// Unfunded real wallet: prove a cold unlock cannot unlock the UI or send,
    /// and foreground takeover preserves the running daemon and its identity.
    func testColdBackgroundUnlockAndForegroundAuthentication() async throws {
        guard ProcessInfo.processInfo.environment["WAVELENGTH_UI_SIGNET"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_UI_SIGNET=1 for cold background startup")
        }
        continueAfterFailure = false
        let fixture = Fixture()
        let client = WalletClient()
        addTeardownBlock {
            try await client.stop()
            await fixture.cleanup()
        }
        fixture.defaults.set(false, forKey: "biometricUnlockEnabled")
        var setup: WalletStore? = fixture.store(client, active: { true })
        await setup!.start()
        await setup!.createWallet(showBackup: false, password: "legacy-wallet-password")
        XCTAssertTrue(setup!.phase.isWalletAvailable, setup!.alertMessage ?? "")
        let originalIdentity = try await client.getInfo().identityPubKey
        let originalSecret = try XCTUnwrap(KeychainStore.read(account: fixture.account))
        try await client.stop()
        setup = nil

        fixture.defaults.set(true, forKey: "biometricUnlockEnabled")
        var active = false
        var authentications = 0
        let store = WalletStore(defaults: fixture.defaults, client: client, dataRoot: fixture.root,
            authenticate: { authentications += 1 }, applicationIsActive: { active })
        // Expiration during native startup cancels only this attempt and joins
        // its cleanup before a second background opportunity can start.
        let cancelledLease = ReceiptFetchLease { _ in }
        let cancelled = Task { await store.prepareBackgroundWallet(windowID: "cancelled", lease: cancelledLease) }
        await waitForStartup(store)
        cancelledLease.expire()
        await store.cancelReceiptWindow("cancelled")
        let cancelledReady = await cancelled.value
        XCTAssertFalse(cancelledReady)
        XCTAssertTrue(store.isSessionLocked)
        XCTAssertNil(store.notificationRuntimeIdentity)
        XCTAssertEqual(try KeychainStore.read(account: fixture.account), originalSecret)

        // A foreground transition owns the next startup only after the cold
        // preparation has observed cancellation and relinquished its owner.
        let takeover = Task { await store.prepareBackgroundWallet(windowID: "takeover", lease: ReceiptFetchLease { _ in }) }
        await waitForStartup(store)
        active = true
        await store.resumeAfterBackground()
        let takeoverReady = await takeover.value
        XCTAssertFalse(takeoverReady)
        XCTAssertTrue(store.isSessionLocked)
        XCTAssertEqual(store.phase, .needsUnlock)
        XCTAssertEqual(authentications, 0)
        try await client.stop()
        active = false

        let lease = ReceiptFetchLease { _ in }
        let prepared = await store.prepareBackgroundWallet(windowID: "cold", lease: lease,
                                                           expectedIdentity: originalIdentity)
        XCTAssertTrue(prepared)
        XCTAssertTrue(store.isSessionLocked)
        XCTAssertNil(store.notificationIdentity)
        XCTAssertEqual(store.notificationRuntimeIdentity, originalIdentity)
        XCTAssertEqual(authentications, 0, "Background must never prompt")
        XCTAssertEqual(try KeychainStore.read(account: fixture.account), originalSecret)
        let backgroundInfo = try await client.getInfo()
        XCTAssertFalse(backgroundInfo.serverConnected, "Cold startup must leave automatic intake paused")
        do { _ = try await store.exportRecovery(outpoints: []); XCTFail("Background export was admitted") }
        catch { XCTAssertEqual(error.localizedDescription, "Unlock Wavelength to continue.") }
        do { _ = try await store.sendPrepared(invalidQuote()); XCTFail("Background send was admitted") }
        catch { XCTAssertEqual(error.localizedDescription, "Unlock Wavelength to continue.") }
        _ = try await store.runMaintenanceWindow("cold")
        XCTAssertTrue(store.isSessionLocked)

        active = true
        await store.resumeAfterBackground()
        XCTAssertTrue(store.isSessionLocked)
        await store.unlockWithBiometrics()
        XCTAssertFalse(store.isSessionLocked, store.alertMessage ?? "")
        XCTAssertEqual(authentications, 1)
        let foregroundInfo = try await client.getInfo()
        XCTAssertEqual(foregroundInfo.identityPubKey, originalIdentity)
        XCTAssertTrue(foregroundInfo.serverConnected)

        // Existing user passwords remain valid without re-encrypting the wallet.
        store.lockForBackground()
        await store.unlockWallet(password: "wrong")
        XCTAssertTrue(store.isSessionLocked)
        await store.unlockWallet(password: "legacy-wallet-password")
        XCTAssertFalse(store.isSessionLocked, store.alertMessage ?? "")

        // Returning during a warm window must resume its intake without
        // replacing the daemon, including when UI authentication is disabled.
        await store.setBiometricUnlock(false)
        let generation = store.notificationGeneration
        active = false
        store.lockForBackground()
        let warmReady = await store.prepareBackgroundWallet(windowID: "deferred", lease: ReceiptFetchLease { _ in })
        XCTAssertTrue(warmReady)
        let window = Task { try await store.runMaintenanceWindow("deferred") }
        let admissionDeadline = Date().addingTimeInterval(5)
        while store.canChangeNetwork && Date() < admissionDeadline { await Task.yield() }
        XCTAssertFalse(store.canChangeNetwork)
        active = true
        await store.resumeAfterBackground()
        await store.cancelReceiptWindow("deferred")
        _ = try? await window.value
        let resumeDeadline = Date().addingTimeInterval(5)
        while !(try await client.getInfo().serverConnected) && Date() < resumeDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.notificationGeneration, generation, "Paused intake is not a reason to replace the daemon")
        let resumed = try await client.getInfo()
        XCTAssertTrue(resumed.serverConnected)
        XCTAssertFalse(store.isSessionLocked)
    }

    func testGeneratedCredentialSurvivesForegroundTransitionDuringCreation() async throws {
        guard ProcessInfo.processInfo.environment["WAVELENGTH_UI_SIGNET"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_UI_SIGNET=1 for managed wallet creation")
        }
        let fixture = Fixture()
        let client = WalletClient()
        addTeardownBlock {
            try await client.stop()
            await fixture.cleanup()
        }
        guard WalletAuthentication.available else { throw XCTSkip("Device authentication unavailable") }
        var active = true
        var authentications = 0
        let store = WalletStore(defaults: fixture.defaults, client: client, dataRoot: fixture.root,
            authenticate: { authentications += 1; active = false },
            waitForForeground: { active = true }, applicationIsActive: { active })
        await store.start()
        let creation = Task { await store.createWallet(showBackup: false) }
        let deadline = Date().addingTimeInterval(5)
        while try KeychainStore.read(account: fixture.account) == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let durableSecret = try XCTUnwrap(KeychainStore.read(account: fixture.account))
        XCTAssertEqual(durableSecret.count, 32)
        // Face ID can return an active scene while CreateWallet is still in flight.
        await store.resumeAfterBackground()
        XCTAssertEqual(try KeychainStore.read(account: fixture.account), durableSecret)
        await creation.value
        XCTAssertTrue(store.phase.isWalletAvailable, store.alertMessage ?? "")
        XCTAssertFalse(store.hasPasswordFallback)
        XCTAssertTrue(store.biometricUnlockEnabled)
        XCTAssertEqual(authentications, 1)
        XCTAssertEqual(try KeychainStore.read(account: fixture.account), durableSecret)
        try await client.stop()
        store.lockForBackground()
        await store.start()
        XCTAssertTrue(store.isSessionLocked)
        await store.unlockWithBiometrics()
        XCTAssertEqual(authentications, 2)
        XCTAssertFalse(store.isSessionLocked, store.alertMessage ?? "")
        XCTAssertTrue(store.phase.isWalletAvailable, store.alertMessage ?? "")

        // Device backups can restore encrypted files without ThisDeviceOnly
        // keys. Preserve those files and show a useful state instead of a
        // passwordless unlock screen. Restoring the key reopens the same wallet.
        let identity = try await client.getInfo().identityPubKey
        try await client.stop()
        try KeychainStore.delete(account: fixture.account)
        store.lockForBackground()
        await store.start()
        XCTAssertTrue(store.managedKeyUnavailable)
        XCTAssertEqual(store.phase, .needsUnlock)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.path))
        try KeychainStore.save(durableSecret, account: fixture.account)
        await store.start()
        XCTAssertFalse(store.managedKeyUnavailable)
        await store.unlockWithBiometrics()
        let restored = try await client.getInfo()
        XCTAssertEqual(restored.identityPubKey, identity)
        XCTAssertFalse(store.isSessionLocked, store.alertMessage ?? "")
    }

    func testOldAmountConsentDoesNotEnableLockedWalletAmounts() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store(WalletClient(), active: { true })
        let notifications = WalletNotifications(defaults: fixture.defaults)
        notifications.retainWarmStore(store)
        fixture.defaults.set(true, forKey: "notifications.amounts.signet")
        XCTAssertFalse(notifications.amountsEnabled)
        fixture.defaults.set(true, forKey: "notifications.amounts.v2.signet")
        XCTAssertTrue(notifications.amountsEnabled)
    }

    func testAuthenticationWaitsForActiveButCannotSurviveBackground() async throws {
        for enterBackground in [false, true] {
            let fixture = Fixture()
            defer { fixture.cleanup() }
            fixture.defaults.set(false, forKey: "biometricUnlockEnabled")
            var active = true
            weak var current: WalletStore?
            let store = WalletStore(defaults: fixture.defaults, dataRoot: fixture.root,
                authenticate: {
                    active = false
                    if enterBackground { current?.lockForBackground() }
                }, waitForForeground: { active = true }, applicationIsActive: { active })
            current = store
            await store.setBiometricUnlock(true)
            XCTAssertEqual(store.biometricUnlockEnabled, !enterBackground)
        }
    }

    func testAuthenticationWaitDoesNotExpireWhilePromptDismisses() async throws {
        var state = UIApplication.State.inactive
        var completed = false
        let wait = Task {
            try await WalletAuthentication.waitForForeground(applicationState: { state })
            completed = true
        }
        defer { wait.cancel() }
        // Real Face ID dismissal on device exceeded the old two-second cap.
        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertFalse(completed)
        state = .active
        try await wait.value
        XCTAssertTrue(completed)
    }

    func testAuthenticationWaitRejectsBackgroundAndCancellation() async throws {
        do {
            try await WalletAuthentication.waitForForeground(applicationState: { .background })
            XCTFail("Background authentication was accepted")
        } catch {
            XCTAssertEqual((error as? LAError)?.code, .systemCancel)
        }
        let wait = Task {
            try await WalletAuthentication.waitForForeground(applicationState: { .inactive })
        }
        wait.cancel()
        do {
            try await wait.value
            XCTFail("Cancelled authentication was accepted")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testUnlockWaitsForStartupAndFailureRemainsRetryable() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: "biometricUnlockEnabled")
        let gate = StartupGate()
        var authentications = 0
        var starts = 0
        let store = WalletStore(defaults: fixture.defaults, dataRoot: fixture.root,
            authenticate: { authentications += 1 }, applicationIsActive: { true },
            startClient: { _ in
                starts += 1
                await gate.wait()
                throw WalletActionError(message: "Startup unavailable")
            }, stopClient: {})
        // No native API or authentication prompt is allowed before readiness.
        await store.unlockWithBiometrics()
        await store.unlockWallet(password: "legacy")
        XCTAssertNil(store.alertMessage)
        XCTAssertEqual(authentications, 0)

        let startup = Task { await store.start() }
        while starts == 0 { await Task.yield() }
        XCTAssertEqual(store.phase, .starting)
        await store.unlockWithBiometrics()
        await store.unlockWallet(password: "legacy")
        XCTAssertNil(store.alertMessage)
        XCTAssertEqual(authentications, 0)
        gate.open()
        await startup.value
        XCTAssertEqual(store.phase, .failed("Startup unavailable"))
        XCTAssertTrue(store.isSessionLocked)
        await store.unlockWithBiometrics()
        await store.unlockWallet(password: "legacy")
        XCTAssertNil(store.alertMessage)
        XCTAssertEqual(authentications, 0)
        await store.start()
        XCTAssertEqual(starts, 2, "The failure screen can retry startup while locked")
    }

    func testForegroundStartJoinsPendingCleanupBeforeStarting() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        var calls: [String] = []
        var pending = true
        let store = WalletStore(defaults: fixture.defaults, dataRoot: fixture.root,
            applicationIsActive: { true },
            startClient: { _ in
                calls.append("start")
                throw WalletActionError(message: "Fixture startup complete")
            }, stopClient: {
                calls.append("stop")
                if pending {
                    throw WalletError(message: "wavewalletdk mobile stop pending; call Stop again: deadline exceeded")
                }
            })
        await store.start()
        XCTAssertEqual(calls, ["stop"], "isRunning false cannot bypass unfinished cleanup")
        pending = false
        await store.start()
        XCTAssertEqual(calls, ["stop", "stop", "start"])
    }

    func testColdBackgroundStartJoinsPendingCleanupBeforeStarting() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try KeychainStore.save(Data("device-managed".utf8), account: fixture.account)
        var calls: [String] = []
        var pending = true
        let store = WalletStore(defaults: fixture.defaults, dataRoot: fixture.root,
            applicationIsActive: { false },
            startClient: { _ in
                calls.append("start")
                throw WalletActionError(message: "Fixture startup complete")
            }, stopClient: {
                calls.append("stop")
                if pending {
                    throw WalletError(message: "wavewalletdk mobile stop pending; call Stop again: deadline exceeded")
                }
            })
        let first = await store.prepareBackgroundWallet(windowID: "first", lease: ReceiptFetchLease { _ in })
        XCTAssertFalse(first)
        XCTAssertEqual(calls, ["stop"])
        pending = false
        let second = await store.prepareBackgroundWallet(windowID: "second", lease: ReceiptFetchLease { _ in })
        XCTAssertFalse(second)
        XCTAssertEqual(calls, ["stop", "stop", "start", "stop"],
                       "Only a start owned by this attempt needs failure cleanup")
    }

    @MainActor private final class StartupGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func waitForStartup(_ store: WalletStore) async {
        let deadline = Date().addingTimeInterval(5)
        while store.phase != .starting && Date() < deadline { await Task.yield() }
        XCTAssertEqual(store.phase, .starting)
    }

    private func invalidQuote() throws -> PrepareSendResult {
        try JSONDecoder().decode(PrepareSendResult.self, from: Data(#"{"SendIntentID":"never-dispatch","AmountSat":1000,"ExpectedFeeSat":0,"FeeKnown":true,"ExpectedTotalOutflowSat":1000,"Rail":"lightning","QuoteStatus":"ready","DestinationSummary":"test","PaymentHash":"","Warning":""}"#.utf8))
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "background-wallet-" + UUID().uuidString
        let defaults: UserDefaults
        var account: String { root.lastPathComponent + ".wallet-password-signet" }
        init() { defaults = UserDefaults(suiteName: suite)!; defaults.set("signet", forKey: "selectedNetwork") }
        func store(_ client: WalletClient, active: @escaping @MainActor () -> Bool) -> WalletStore {
            WalletStore(defaults: defaults, client: client, dataRoot: root,
                        authenticate: {}, applicationIsActive: active)
        }
        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            try? KeychainStore.delete(account: account)
            try? KeychainStore.delete(account: account + ".verifier")
            try? WalletAuthentication.delete(account: account)
        }
    }
}
