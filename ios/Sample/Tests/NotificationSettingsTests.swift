import XCTest
import WalletKit
@testable import Wavelength

@MainActor
final class NotificationSettingsTests: XCTestCase {
    func testPermissionRequestPublishesProgressAndRejectsDuplicateTap() async {
        let suite = "notification-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WalletStore(defaults: defaults)
        var requests = 0
        var permission: CheckedContinuation<Bool, Never>?
        let notifications = WalletNotifications(defaults: defaults, configuration: { _ in Self.configuration }, authorize: {
            requests += 1
            return await withCheckedContinuation { permission = $0 }
        }, registerDevice: {})
        notifications.retainWarmStore(store)
        let request = Task { await notifications.setEnabled(true) }
        while permission == nil { await Task.yield() }
        XCTAssertTrue(notifications.working)
        XCTAssertEqual(notifications.settingsStatus, "Waiting for notification permission…")
        await notifications.setEnabled(true)
        XCTAssertEqual(requests, 1)
        permission?.resume(returning: false)
        await request.value
        XCTAssertFalse(notifications.working)
        XCTAssertFalse(notifications.enabled)
        XCTAssertTrue(notifications.settingsStatus.contains("iOS Settings"))
    }

    func testPermissionErrorStaysVisibleWithoutReconciliationOverwritingIt() async {
        enum Failure: Error { case permission }
        let suite = "notification-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WalletStore(defaults: defaults)
        let notifications = WalletNotifications(defaults: defaults, configuration: { _ in Self.configuration },
            authorize: { throw Failure.permission }, registerDevice: {})
        notifications.retainWarmStore(store)
        await notifications.setEnabled(true)
        notifications.reconcile()
        while notifications.working { await Task.yield() }
        XCTAssertFalse(notifications.working)
        XCTAssertFalse(notifications.enabled)
        XCTAssertEqual(notifications.settingsStatus, "Couldn’t request notification permission. Try again.")
        notifications.registered(token: Data([1]))
        while notifications.working { await Task.yield() }
        XCTAssertEqual(notifications.settingsStatus, "Couldn’t request notification permission. Try again.")
    }

    func testUnavailableConnectionExplainsWhyBeforeAndAfterTap() async {
        let suite = "notification-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WalletStore(defaults: defaults)
        let notifications = WalletNotifications(defaults: defaults, configuration: { _ in nil },
            authorize: { XCTFail("No permission request without relay configuration"); return true }, registerDevice: {})
        notifications.retainWarmStore(store)
        XCTAssertTrue(notifications.settingsStatus.contains("in this build"))
        await notifications.setEnabled(true)
        XCTAssertFalse(notifications.enabled)
        XCTAssertTrue(notifications.settingsStatus.contains("in this build"))
    }

    private static var configuration: NotificationRelayConfiguration {
        NotificationRelayConfiguration(origin: "https://relay.example", appAlias: "wallet", swapIssuer: "02" + String(repeating: "01", count: 32), receiptHints: true)!
    }
}
