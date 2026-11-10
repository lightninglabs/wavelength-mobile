import Security
import XCTest
import WalletKit
@testable import Wavelength

@MainActor
final class WalletLifecycleTests: XCTestCase {
    func testBiometricPolicyAndMigrationPreserveDistinctPasswords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "wavelength-auth-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let accounts = WalletNetwork.allCases.map { root.lastPathComponent + ".wallet-password-\($0.rawValue)" }
        defer {
            defaults.removePersistentDomain(forName: suite)
            for account in accounts {
                try? KeychainStore.delete(account: account)
                try? WalletAuthentication.delete(account: account)
            }
        }
        let signet = root.lastPathComponent + ".wallet-password-signet"
        let mainnet = root.lastPathComponent + ".wallet-password-mainnet"
        let signetSecret = Data("signet-password".utf8)
        let mainnetSecret = Data("mainnet-password".utf8)
        try seedSurvivingBiometricItem(signetSecret, account: signet)
        try KeychainStore.save(mainnetSecret, account: mainnet)

        // An existing protected Signet wallet enables the policy everywhere,
        // including networks that do not yet have a wallet or protected key.
        for network in WalletNetwork.allCases {
            defaults.set(network.rawValue, forKey: "selectedNetwork")
            XCTAssertTrue(WalletStore(defaults: defaults, dataRoot: root).biometricUnlockEnabled)
        }
        try seedSurvivingBiometricItem(mainnetSecret, account: mainnet)
        try KeychainStore.delete(account: mainnet)
        defaults.set("mainnet", forKey: "selectedNetwork")
        let store = WalletStore(defaults: defaults, dataRoot: root)
        XCTAssertTrue(store.needsPasswordMigration)
        await store.setBiometricUnlock(false)
        XCTAssertTrue(store.biometricUnlockEnabled, "A locked session cannot disable app authentication")
        // Successful legacy authentication supplies each network's own secret.
        defaults.set(true, forKey: "biometricUnlockEnabled")
        try WalletAuthentication.migrate(signetSecret, account: signet)
        try WalletAuthentication.migrate(mainnetSecret, account: mainnet)
        XCTAssertEqual(try KeychainStore.read(account: signet), signetSecret)
        XCTAssertEqual(try KeychainStore.read(account: mainnet), mainnetSecret)
        XCTAssertFalse(store.needsPasswordMigration)
        XCTAssertFalse(WalletAuthentication.contains(account: signet))
        XCTAssertFalse(WalletAuthentication.contains(account: mainnet))
        XCTAssertTrue(WalletStore(defaults: defaults, dataRoot: root).biometricUnlockEnabled)

        defaults.set(true, forKey: "biometricUnlockEnabled")
        XCTAssertTrue(WalletStore(defaults: defaults, dataRoot: root).biometricUnlockEnabled)
    }

    func testColdActivationWaitsForTransientInactiveScene() async throws {
        guard ProcessInfo.processInfo.environment["WAVELENGTH_UI_SIGNET"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_UI_SIGNET=1 for the live lifecycle probe")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "wavelength-inactive-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "biometricUnlockEnabled")
        let client = WalletClient()
        addTeardownBlock {
            try await client.stop()
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? KeychainStore.delete(account: root.lastPathComponent + ".wallet-password-signet")
        }
        let setup = WalletStore(defaults: defaults, client: client, dataRoot: root)
        await setup.start()
        await setup.createWallet(showBackup: false)
        XCTAssertTrue(setup.phase.isWalletAvailable, setup.alertMessage ?? "")
        try await client.stop()
        var active = false
        var waited = false
        let reopened = WalletStore(defaults: defaults, client: client, dataRoot: root,
            waitForForeground: { waited = true; active = true },
            applicationIsActive: { active })
        await reopened.start()
        XCTAssertTrue(waited, "Activation must wait through transient inactivity")
        XCTAssertTrue(reopened.phase.isWalletAvailable)
        XCTAssertNotNil(reopened.balance)
        XCTAssertTrue(reopened.activityLoaded)
    }

    func testSwitchingToExistingMainnetRequiresAuthentication() async throws {
        guard ProcessInfo.processInfo.environment["WAVELENGTH_UI_SIGNET"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_UI_SIGNET=1 for the live lifecycle probe")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "wavelength-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("mainnet", forKey: "selectedNetwork")
        defaults.set(false, forKey: "biometricUnlockEnabled")
        let mainnet = root.lastPathComponent + ".wallet-password-mainnet"
        let signet = root.lastPathComponent + ".wallet-password-signet"
        let client = WalletClient()
        addTeardownBlock {
            try await client.stop()
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
            for account in [mainnet, signet] {
                try? KeychainStore.delete(account: account)
                try? KeychainStore.delete(account: account + ".verifier")
                try? WalletAuthentication.delete(account: account)
            }
        }
        do {
            let setup = WalletStore(defaults: defaults, client: client, dataRoot: root)
            await setup.start()
            await setup.createWallet(showBackup: false, password: "mainnet-test-password")
            XCTAssertTrue(setup.phase.isWalletAvailable, setup.alertMessage ?? "")
        }
        // Simulate an older installation where only Signet had Face ID enabled.
        try seedSurvivingBiometricItem(Data("different-signet-password".utf8), account: signet)
        defaults.set("signet", forKey: "selectedNetwork")
        let switched = WalletStore(defaults: defaults, client: client, dataRoot: root)
        await switched.switchNetwork(to: .mainnet)
        XCTAssertEqual(switched.phase, .needsUnlock)
        XCTAssertTrue(switched.isSessionLocked)
        await switched.unlockWallet(password: "different-signet-password")
        XCTAssertTrue(switched.isSessionLocked)
        await switched.unlockWallet(password: "mainnet-test-password")
        XCTAssertFalse(switched.isSessionLocked, switched.alertMessage ?? "")
        switched.lockForBackground()
        XCTAssertTrue(switched.isSessionLocked)
        await switched.unlockWallet(password: "mainnet-test-password")
        XCTAssertFalse(switched.isSessionLocked, switched.alertMessage ?? "")
        XCTAssertEqual(try KeychainStore.read(account: mainnet), Data("mainnet-test-password".utf8))
    }

    /// Uses an unfunded fixture and real native subscription. A daemon restart
    /// during password fallback closes that subscription and fails the test.
    func testStaleCredentialsAndPasswordFallbackKeepTheDaemonAlive() async throws {
        guard ProcessInfo.processInfo.environment["WAVELENGTH_UI_SIGNET"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_UI_SIGNET=1 for the live lifecycle probe")
        }
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "wavelength-lifecycle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("signet", forKey: "selectedNetwork")
        defaults.set(false, forKey: "biometricUnlockEnabled")
        let account = root.lastPathComponent + ".wallet-password-signet"
        let client = WalletClient()
        addTeardownBlock {
            try await client.stop()
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? KeychainStore.delete(account: account)
            try? KeychainStore.delete(account: account + ".verifier")
            try? WalletAuthentication.delete(account: account)
        }
        let password = "chosen-test-password"
        let secret = Data(password.utf8)
        try KeychainStore.save(Data("stale password".utf8), account: account)
        try seedSurvivingBiometricItem(secret, account: account)
        do {
            let setup = WalletStore(defaults: defaults, client: client, dataRoot: root)
            await setup.start()
            XCTAssertEqual(setup.phase, .needsSetup)
            XCTAssertFalse(setup.isSessionLocked)
            XCTAssertFalse(setup.biometricUnlockEnabled)
            XCTAssertNil(try KeychainStore.read(account: account))
            XCTAssertFalse(WalletAuthentication.contains(account: account))

            // A failed prior attempt must not override a newly supplied password.
            try KeychainStore.save(Data("prior attempt".utf8), account: account)
            await setup.createWallet(showBackup: false, password: password)
            XCTAssertEqual(try KeychainStore.read(account: account), secret)
        }

        // Seed only the Keychain identity used to discover enabled biometrics;
        // Simulator enrollment is outside this password-fallback test.
        try seedSurvivingBiometricItem(secret, account: account)
        try KeychainStore.delete(account: account)
        let store = WalletStore(defaults: defaults, client: client, dataRoot: root)
        await store.start()
        XCTAssertTrue(store.isSessionLocked)
        await store.unlockWallet(password: password)
        XCTAssertFalse(store.isSessionLocked, store.alertMessage ?? "")

        // This deliberately invalid reference cannot match a native prepared
        // intent. A definitive rejection must release the durable UI marker.
        let invalid = try JSONDecoder().decode(PrepareSendResult.self, from: Data(#"{"SendIntentID":"expired-test-intent","AmountSat":1000,"ExpectedFeeSat":0,"FeeKnown":true,"ExpectedTotalOutflowSat":1000,"Rail":"lightning","QuoteStatus":"ready","DestinationSummary":"test","PaymentHash":"","Warning":""}"#.utf8))
        do {
            _ = try await store.sendPrepared(invalid)
            XCTFail("An invalid intent must be rejected")
        } catch {
            XCTAssertTrue((error as? WalletError)?.isSendRejectedBeforeDispatch == true)
        }
        XCTAssertNil(store.pendingDispatch)

        let unexpectedEnd = expectation(description: "Subscription must survive password unlock")
        unexpectedEnd.isInverted = true
        let stopped = expectation(description: "Explicit Stop closes the subscription")
        let completion = SubscriptionCompletion()
        let stream = client.activity()
        let observer = Task {
            do { for try await _ in stream {} } catch {}
            if completion.stopping { stopped.fulfill() } else { unexpectedEnd.fulfill() }
        }
        defer { observer.cancel() }
        store.lockForBackground()
        XCTAssertTrue(store.isSessionLocked)
        await store.unlockWallet(password: "wrong password")
        XCTAssertTrue(store.isSessionLocked)
        await store.unlockWallet(password: password)
        XCTAssertFalse(store.isSessionLocked, store.alertMessage ?? "")
        await fulfillment(of: [unexpectedEnd], timeout: 2)
        // Positive control: a real Stop must close that same subscription.
        completion.stopping = true
        try await client.stop()
        await fulfillment(of: [stopped], timeout: 5)
    }

    private func seedSurvivingBiometricItem(_ secret: Data, account: String) throws {
        try WalletAuthentication.delete(account: account)
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "engineering.lightning.wavelength.wallet.biometric",
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
        ] as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
    }

    @MainActor private final class SubscriptionCompletion {
        var stopping = false
    }
}
