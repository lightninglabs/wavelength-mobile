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
        let request = Task { await notifications.setAlertsEnabled(true) }
        while permission == nil { await Task.yield() }
        XCTAssertTrue(notifications.working)
        XCTAssertEqual(notifications.settingsStatus, "Waiting for notification permission…")
        await notifications.setAlertsEnabled(true)
        XCTAssertEqual(requests, 1)
        permission?.resume(returning: false)
        await request.value
        XCTAssertFalse(notifications.working)
        XCTAssertFalse(notifications.alertsEnabled)
        XCTAssertTrue(notifications.enabled, "Alert denial must not disable protocol work")
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
        await notifications.setAlertsEnabled(true)
        notifications.reconcile()
        while notifications.working { await Task.yield() }
        XCTAssertFalse(notifications.working)
        XCTAssertFalse(notifications.alertsEnabled)
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
        await notifications.setAlertsEnabled(true)
        XCTAssertTrue(notifications.enabled, "Scheduled work does not require a relay")
        XCTAssertFalse(notifications.alertsEnabled)
        XCTAssertTrue(notifications.settingsStatus.contains("in this build"))
    }

    func testNewWalletEnablesWorkWithoutAlertAuthorization() async {
        let suite = "background-consent-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WalletStore(defaults: defaults)
        var registrations = 0
        let notifications = WalletNotifications(defaults: defaults, configuration: { _ in Self.configuration },
            authorize: { XCTFail("Protocol work must not request alert permission"); return false },
            registerDevice: { registrations += 1 })
        notifications.retainWarmStore(store)
        XCTAssertTrue(notifications.enabled)
        XCTAssertFalse(notifications.alertsEnabled)
        await notifications.setEnabled(true)
        while notifications.working { await Task.yield() }
        XCTAssertGreaterThan(registrations, 0)
        XCTAssertTrue(notifications.enabled)
        XCTAssertFalse(notifications.alertsEnabled)
    }

    func testScheduledWorkSurvivesMissingRelayAndEarlyStoreAttachment() async {
        let suite = "scheduled-work-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preparations = 0
        let notifications = WalletNotifications(defaults: defaults, configuration: { _ in nil },
            authorize: { XCTFail("Scheduling needs no banner permission"); return false },
            registerDevice: { XCTFail("No relay enrollment for a missing configuration") },
            prepareWork: { _, _, _, _ in preparations += 1; return false })
        XCTAssertTrue(notifications.scheduledWorkEnabled,
                      "Cold registration must retain the schedule chain before store attachment")
        let store = WalletStore(defaults: defaults)
        notifications.retainWarmStore(store)
        XCTAssertTrue(notifications.scheduledWorkEnabled)
        XCTAssertTrue(notifications.enabled)
        let lease = ReceiptFetchLease { _ in }
        _ = await notifications.runMaintenance(windowID: "no-relay", lease: lease)
        XCTAssertEqual(preparations, 1, "Scheduled work must reach preparation with no relay")
        await notifications.setEnabled(false)
        while notifications.working { await Task.yield() }
        XCTAssertFalse(notifications.scheduledWorkEnabled)
        _ = await notifications.runMaintenance(windowID: "opted-out", lease: lease)
        XCTAssertEqual(preparations, 1, "Explicit work opt-out must still refuse preparation")
        await notifications.setEnabled(true)
        while notifications.working { await Task.yield() }
        XCTAssertTrue(notifications.scheduledWorkEnabled)
        XCTAssertFalse(notifications.alertsEnabled)
    }

    func testLegacyOptOutAndOptInMigrateWithoutChangingTheirMeaning() async {
        for legacy in [false, true] {
            let suite = "legacy-notifications-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(legacy, forKey: "notifications.enabled.signet")
            let store = WalletStore(defaults: defaults)
            let notifications = WalletNotifications(defaults: defaults, configuration: { _ in Self.configuration },
                authorize: { XCTFail("Reading/migrating preferences is not alert consent"); return false }, registerDevice: {})
            notifications.retainWarmStore(store)
            XCTAssertEqual(notifications.enabled, legacy)
            XCTAssertEqual(notifications.alertsEnabled, legacy)
            if !legacy {
                await notifications.setEnabled(true)
                while notifications.working { await Task.yield() }
                XCTAssertTrue(notifications.enabled)
                XCTAssertFalse(notifications.alertsEnabled, "Explicit background enable must not opt into banners")
            }
            XCTAssertEqual(defaults.bool(forKey: "notifications.enabled.signet"), legacy)
        }
    }

    func testWorkRoutesSurviveHiddenBannersButKeepOptOutAndNetworkFences() throws {
        let suite = "work-routes-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = "02" + String(repeating: "01", count: 32)
        func route(_ id: String, network: String = "signet", source: NotificationSource = .swapServer) -> WalletNotificationRoute {
            WalletNotificationRoute(id: id, network: network, identity: owner, relay: Self.configuration,
                source: source, boundGrant: "signed-and-bound", boundExpiresAt: Int64(Date().timeIntervalSince1970) + 3600)
        }
        defaults.set(try JSONEncoder().encode([route("receive"), route("operator", source: .arkOperator),
            route("inactive", network: "mainnet")]), forKey: "notifications.routes")
        let store = WalletStore(defaults: defaults)
        let notifications = WalletNotifications(defaults: defaults, configuration: { _ in Self.configuration }, registerDevice: {})
        notifications.retainWarmStore(store)
        let payment: [AnyHashable: Any] = ["wavelength": ["version": 1, "route_id": "receive"]]
        XCTAssertNotNil(notifications.validWakeRoute("receive"))
        XCTAssertNotNil(notifications.validWakeRoute("operator"))
        XCTAssertNil(notifications.validWakeRoute("inactive"), "A push cannot select another wallet")
        XCTAssertNil(notifications.validPaymentRoute("receive"))
        XCTAssertFalse(notifications.permitsPresentation(payment))
        defaults.set(true, forKey: "notifications.alerts.v1.signet")
        XCTAssertNotNil(notifications.validPaymentRoute("receive"))
        XCTAssertTrue(notifications.permitsPresentation(payment))
        XCTAssertFalse(notifications.permitsPresentation(["wavelength": ["version": 1, "route_id": "operator"]]))
        defaults.set(false, forKey: "notifications.alerts.v1.signet")
        XCTAssertNotNil(notifications.validWakeRoute("receive"), "Hiding banners keeps work authorized")
        defaults.set(false, forKey: "notifications.work.v1.signet")
        XCTAssertNil(notifications.validWakeRoute("receive"))
        XCTAssertNil(notifications.validWakeRoute("operator"))
        XCTAssertFalse(notifications.permitsPresentation(payment))
    }

    private static var configuration: NotificationRelayConfiguration {
        NotificationRelayConfiguration(origin: "https://relay.example", appAlias: "wallet", swapIssuer: "02" + String(repeating: "01", count: 32), receiptHints: true)!
    }
}
