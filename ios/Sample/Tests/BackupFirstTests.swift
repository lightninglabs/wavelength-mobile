import XCTest
import WalletKit
@testable import Wavelength

/// Real native wallets with an unreachable chain endpoint. No funds, public
/// services, phrase logging, clipboard access, or screenshots are involved.
@MainActor
final class BackupFirstTests: XCTestCase {
    func testRestartBeforeBackupLeavesWalletUninitialized() async throws {
        let fixture = try Fixture()
        let client = WalletClient()
        addTeardownBlock { try await client.stop(); await fixture.cleanup() }
        var store: WalletStore? = fixture.store(client)
        await store!.start()
        XCTAssertEqual(store!.phase, .needsSetup)
        await store!.prepareWalletBackup()
        XCTAssertEqual(store!.pendingMnemonic?.count, 24)
        XCTAssertFalse(store!.canChangeNetwork)
        let prepared = try await client.getInfo()
        XCTAssertEqual(prepared.walletState, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.wallet.path))
        XCTAssertNil(try KeychainStore.read(account: fixture.account))

        // Release all host state and restart the native daemon, as a process
        // termination would. There is no persisted wallet or pending phrase.
        try await client.stop()
        store = nil
        let reopened = fixture.store(client)
        await reopened.start()
        XCTAssertEqual(reopened.phase, .needsSetup)
        XCTAssertTrue(reopened.pendingMnemonic == nil)
        let after = try await client.getInfo()
        XCTAssertEqual(after.walletState, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.wallet.path))
        XCTAssertNil(try KeychainStore.read(account: fixture.account))
    }

    func testStartupFailureCanCreateDatabaseOnlyAfterBackupAcknowledgment() async throws {
        let fixture = try Fixture()
        let client = WalletClient()
        addTeardownBlock { try await client.stop(); await fixture.cleanup() }
        let store = fixture.store(client)
        await store.start()
        await store.prepareWalletBackup()
        XCTAssertEqual(store.pendingMnemonic?.count, 24)
        XCTAssertNil(store.alertMessage, "Seed preparation must not contact Esplora")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.wallet.path))

        // The user has backed up the words before this call can persist keys.
        await store.acknowledgeSeedBackup()
        XCTAssertNotNil(store.alertMessage)
        XCTAssertTrue(store.pendingMnemonic == nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.wallet.path))
        let state = try await client.getInfo()
        XCTAssertEqual(state.walletState, .locked)
        let secret = try XCTUnwrap(KeychainStore.read(account: fixture.account))
        XCTAssertEqual(secret.count, 32)

        // A retry/restart must retain the initialized wallet and its exact
        // encryption credential. It must never generate a replacement phrase.
        try await client.stop()
        let reopened = fixture.store(client)
        await reopened.start()
        XCTAssertEqual(reopened.phase, .needsUnlock)
        await reopened.prepareWalletBackup()
        XCTAssertTrue(reopened.pendingMnemonic == nil)
        XCTAssertTrue(try KeychainStore.read(account: fixture.account) == secret)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.wallet.path))
    }

    func testBackgroundDiscardsOnlyUninitializedBackup() async throws {
        let fixture = try Fixture()
        fixture.defaults.set(true, forKey: "biometricUnlockEnabled")
        let client = WalletClient()
        addTeardownBlock { try await client.stop(); await fixture.cleanup() }
        let store = fixture.store(client)
        await store.start()
        await store.prepareWalletBackup()
        XCTAssertNotNil(store.pendingMnemonic)
        store.lockForBackground()
        XCTAssertTrue(store.pendingMnemonic == nil)
        XCTAssertEqual(store.phase, .needsSetup)
        XCTAssertTrue(store.isSessionLocked)
        await store.resumeAfterBackground()
        XCTAssertFalse(store.isSessionLocked)
        XCTAssertTrue(store.canChangeNetwork)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.wallet.path))
        XCTAssertNil(try KeychainStore.read(account: fixture.account))
    }

    func testAdmissionFailureRetainsTheAcknowledgedWordsForRetry() async throws {
        let fixture = try Fixture()
        let client = WalletClient()
        addTeardownBlock { try await client.stop(); await fixture.cleanup() }
        var rejectInitialization = false
        var checks = 0
        let store = fixture.store(client, active: {
            guard rejectInitialization else { return true }
            checks += 1
            // Confirmation is admitted, then initialization sees the scene
            // become inactive before any credential or wallet is persisted.
            return checks == 1
        })
        await store.start()
        await store.prepareWalletBackup()
        let backedUpWords = try XCTUnwrap(store.pendingMnemonic)
        rejectInitialization = true
        await store.acknowledgeSeedBackup()
        XCTAssertTrue(store.pendingMnemonic == backedUpWords)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.wallet.path))
        XCTAssertNil(try KeychainStore.read(account: fixture.account))
        XCTAssertNotNil(store.alertMessage)
        XCTAssertFalse(store.alertMessage?.contains("keeps the same encrypted wallet key") ?? true)

        rejectInitialization = false
        await store.acknowledgeSeedBackup()
        XCTAssertTrue(store.pendingMnemonic == nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.wallet.path))
        let state = try await client.getInfo()
        XCTAssertEqual(state.walletState, .locked)
    }

    @MainActor private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        var account: String { root.lastPathComponent + ".wallet-password-signet" }
        var wallet: URL { root.appendingPathComponent("Wavelength/signet/data/signet/wallet.db") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = "wavelength-backup-first-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set("signet", forKey: "selectedNetwork")
            defaults.set(false, forKey: "biometricUnlockEnabled")
            defaults.set("http://127.0.0.1:9", forKey: "signet.esploraAddress")
            defaults.set("127.0.0.1:9", forKey: "signet.operatorAddress")
            defaults.set("127.0.0.1:9", forKey: "signet.swapAddress")
        }

        func store(_ client: WalletClient, active: @escaping @MainActor () -> Bool = { true }) -> WalletStore {
            WalletStore(defaults: defaults, client: client, dataRoot: root, applicationIsActive: active)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? KeychainStore.delete(account: account)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
