import Foundation
import UIKit
import XCTest
import WalletKit
@testable import Wavelength

private final class ReceiptMemoryCredentials: NotificationCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    var rejectWrites = false
    func read(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }; return value
    }
    func save(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectWrites { throw NotificationRelayError.unavailableCredentials }
        value = data
    }
}

@MainActor
final class ReceiptNotificationTests: XCTestCase {
    private let owner = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
    private let paymentHash = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private let event = "aea16881a4d03ec94406d8539aee80b8027806ef6ba01df56d77143eb8118f78"

    func testGoSwiftCorrelationAndInvalidMetadata() {
        XCTAssertEqual(ReceiptEventIdentity.relayHash(owner: owner, paymentHash: paymentHash), event)
        XCTAssertNil(ReceiptEventIdentity.relayHash(owner: owner, paymentHash: "invalid"))
        XCTAssertNil(ReceiptEventIdentity.relayHash(owner: "owner", paymentHash: paymentHash))
        XCTAssertNotEqual(ReceiptEventIdentity.relayHash(owner: "03" + owner.dropFirst(2), paymentHash: paymentHash), event)
    }

    func testWakeAndVisibleRemoteAlertCannotAuthorizeLocalBanner() {
        let payload: [String: Any] = ["version": 1, "route_id": "route", "event_id": event]
        XCTAssertNil(ReceiptPaymentHint(userInfo: ["wavelength": payload, "aps": ["content-available": 1]]))
        var hint = payload
        hint["kind"] = "payment_activity"
        XCTAssertNotNil(ReceiptPaymentHint(userInfo: ["wavelength": hint, "aps": ["content-available": 1]]))
        XCTAssertNil(ReceiptPaymentHint(userInfo: ["wavelength": hint, "aps": ["alert": "Already visible"]]))
        hint["version"] = true
        XCTAssertNil(ReceiptPaymentHint(userInfo: ["wavelength": hint]))
    }

    func testGenericClaimSurvivesReloadAndConsumesExactEnrollment() throws {
        let storage = ReceiptMemoryCredentials()
        let ledger = ReceiptNotificationLedger(storage: storage)
        let consent = try ledger.ensureConsent(network: "signet", now: 100)
        let enrollment = enrolled(consent)
        try ledger.enroll(enrollment, now: 101)
        XCTAssertNotNil(try ledger.enrolled(routeID: "route", eventHash: event, now: 102))
        XCTAssertTrue(try ledger.claim(routeID: "route", eventHash: event, now: 102))
        let restored = ReceiptNotificationLedger(storage: storage)
        XCTAssertNil(try restored.enrolled(routeID: "route", eventHash: event, now: 103))
        XCTAssertFalse(try restored.claim(routeID: "route", eventHash: event, now: 103))
        // A later complete native source cannot re-enroll the old creation.
        try restored.enroll(enrollment, now: 104)
        XCTAssertNil(try restored.enrolled(routeID: "route", eventHash: event, now: 104))
    }

    func testConcurrentEventsKeepIndependentPresentationOwnership() throws {
        let ledger = ReceiptNotificationLedger(storage: ReceiptMemoryCredentials())
        let consent = try ledger.ensureConsent(network: "signet", now: 100)
        try ledger.enroll(enrolled(consent), now: 101)
        XCTAssertTrue(ledger.reservePresentation(routeID: "route", eventHash: event))
        XCTAssertFalse(ledger.reservePresentation(routeID: "route", eventHash: event),
                       "Duplicate must not consume the first callback's enrolled proof")
        // A maintenance window or another invoice does not own this event.
        XCTAssertTrue(ledger.reservePresentation(routeID: "route", eventHash: "other-invoice"))
        XCTAssertTrue(try ledger.claim(routeID: "route", eventHash: "other-invoice", now: 102))
        ledger.releasePresentation(routeID: "route", eventHash: "other-invoice")
        XCTAssertNotNil(try ledger.enrolled(routeID: "route", eventHash: event, now: 103))
        XCTAssertTrue(try ledger.claim(routeID: "route", eventHash: event, now: 103))
        ledger.releasePresentation(routeID: "route", eventHash: event)
        XCTAssertTrue(ledger.reservePresentation(routeID: "route", eventHash: event))
        XCTAssertFalse(try ledger.claim(routeID: "route", eventHash: event, now: 104),
                       "Releasing in-memory ownership never releases the durable claim")
    }

    func testEpochChangeRejectsHistoricalEnrollmentAndStorageFailureDoesNotClaim() throws {
        let storage = ReceiptMemoryCredentials()
        let ledger = ReceiptNotificationLedger(storage: storage)
        let old = try ledger.ensureConsent(network: "signet", now: 100)
        try ledger.enroll(enrolled(old), now: 101)
        try ledger.revoke(network: "signet")
        let current = try ledger.ensureConsent(network: "signet", now: 200)
        XCTAssertNotEqual(old, current)
        try ledger.enroll(enrolled(old), now: 201)
        XCTAssertNil(try ledger.enrolled(routeID: "route", eventHash: event, now: 201))
        storage.rejectWrites = true
        XCTAssertThrowsError(try ledger.claim(routeID: "route", eventHash: event, now: 201))
        storage.rejectWrites = false
        XCTAssertTrue(try ledger.claim(routeID: "route", eventHash: event, now: 202))
    }

    func testOnlyMatchingCompletePrincipalPermitsAmount() throws {
        let enrollment = enrolled(ReceiptConsent(epoch: "epoch", createdAfterUnix: 100))
        let complete = try result()
        XCTAssertTrue(ReceiptNotificationPresentation.body(enrollment: enrollment, result: complete).hasPrefix("You received "))
        for bad in [try result(state: "pending"), try result(amount: 7), try result(created: 100),
                    try result(id: "other"), try result(interrupted: true), try result(needsForeground: true)] {
            XCTAssertEqual(ReceiptNotificationPresentation.body(enrollment: enrollment, result: bad), ReceiptNotificationPresentation.generic)
        }
        XCTAssertEqual(ReceiptNotificationPresentation.body(enrollment: nil, result: complete), ReceiptNotificationPresentation.generic)
        XCTAssertEqual(ReceiptNotificationPresentation.body(enrollment: enrollment, result: nil), ReceiptNotificationPresentation.generic)
    }

    func testFallbackIncludesCallbackQueueingAndPreservesTimeAfterOldCutoff() async {
        var now: TimeInterval = 125
        var completions = 0
        let lease = ReceiptFetchLease(startedAt: 100, uptime: { now }) { _ in completions += 1 }
        var delay: UInt64?
        var wake: CheckedContinuation<Void, Never>?
        let deadline = lease.fallback(sleep: { nanos in
            delay = nanos
            await withCheckedContinuation { wake = $0 }
        }) { lease.expire() }
        while wake == nil { await Task.yield() }
        XCTAssertEqual(delay, 3_000_000_000, "Queueing and preparation share the 28-second fallback")
        XCTAssertFalse(lease.expired, "Work still owns the window after the old 15/20-second cutoffs")
        XCTAssertEqual(completions, 0)
        now = 128
        wake?.resume()
        await deadline.value
        XCTAssertTrue(lease.expired)
        XCTAssertEqual(completions, 1)
        lease.expire()
        lease.finish(.newData)
        XCTAssertEqual(completions, 1)
    }

    func testSystemExpiryAndNormalCompletionSuppressFallback() async {
        for systemExpiry in [true, false] {
            var completions = 0
            var fallbackCalls = 0
            let lease = ReceiptFetchLease { _ in completions += 1 }
            var wake: CheckedContinuation<Void, Never>?
            let deadline = lease.fallback(sleep: { _ in
                await withCheckedContinuation { wake = $0 }
            }) { fallbackCalls += 1; lease.expire() }
            while wake == nil { await Task.yield() }
            if systemExpiry { lease.expire() } else { lease.finish(.newData); deadline.cancel() }
            wake?.resume()
            await deadline.value
            XCTAssertEqual(completions, 1)
            XCTAssertEqual(fallbackCalls, 0)
            XCTAssertEqual(lease.expired, systemExpiry)
        }
    }

    func testExpiryAndNormalReturnFinishFetchExactlyOnce() {
        var completions = 0
        let expired = ReceiptFetchLease { _ in completions += 1 }
        expired.expire()
        expired.finish(.newData)
        expired.expire()
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(expired.expired)
        let normal = ReceiptFetchLease { _ in completions += 1 }
        normal.finish(.noData)
        normal.finish(.newData)
        XCTAssertEqual(completions, 2)
    }

    func testScheduledOpportunityNeverStartsColdWallet() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let notifications = WalletNotifications(defaults: defaults)
        let store = WalletStore()
        notifications.retainWarmStore(store)
        let lease = ReceiptFetchLease { _ in }
        let changed = await notifications.runMaintenance(windowID: "cold", lease: lease)
        XCTAssertFalse(changed)
        if case .idle = store.phase {} else { XCTFail("Background maintenance started a cold wallet") }
    }

    func testSavedNetworkKeepsGenericAuthorityWithoutCurrentWalletConfiguration() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let configuration = try XCTUnwrap(NotificationRelayConfiguration(
            origin: "https://relay.invalid", appAlias: "test", swapIssuer: owner))
        let route = WalletNotificationRoute(id: "other-network", network: "mainnet", identity: owner,
                                            relay: configuration, source: .swapServer)
        let operatorRoute = WalletNotificationRoute(id: "operator", network: "mainnet", identity: owner,
                                                    relay: configuration, source: .arkOperator)
        defaults.set(try JSONEncoder().encode([route, operatorRoute]), forKey: "notifications.routes")
        defaults.set(true, forKey: "notifications.enabled.mainnet")
        let notifications = WalletNotifications(defaults: defaults)
        // No current store, account or bundled endpoint can authorize an amount.
        // The old remote generic banner must still have a local equivalent.
        XCTAssertEqual(notifications.validPaymentRoute(route.id)?.id, route.id)
        XCTAssertNil(notifications.validPaymentRoute(operatorRoute.id))
        XCTAssertNil(notifications.validPaymentRoute("unknown"))
        defaults.set(false, forKey: "notifications.enabled.mainnet")
        XCTAssertNil(notifications.validPaymentRoute(route.id))
    }

    func testForegroundHintDoesNotConsumePresentationClaim() async throws {
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let storage = ReceiptMemoryCredentials()
        let ledger = ReceiptNotificationLedger(storage: storage)
        let configuration = try XCTUnwrap(NotificationRelayConfiguration(
            origin: "https://relay.invalid", appAlias: "test", swapIssuer: owner))
        let route = WalletNotificationRoute(id: "route", network: "signet", identity: owner,
                                            relay: configuration, source: .swapServer)
        defaults.set(try JSONEncoder().encode([route]), forKey: "notifications.routes")
        defaults.set(true, forKey: "notifications.enabled.signet")
        let notifications = WalletNotifications(defaults: defaults, receiptLedger: ledger)
        let store = WalletStore()
        notifications.retainWarmStore(store)
        let changed = await notifications.received([
            "wavelength": ["version": 1, "route_id": "route", "event_id": event, "kind": "payment_activity"],
            "aps": ["content-available": 1],
        ], windowID: "foreground", lease: ReceiptFetchLease { _ in })
        XCTAssertFalse(changed)
        XCTAssertTrue(try ledger.claim(routeID: "route", eventHash: event, now: 200),
                      "Foreground handling must preserve later receipt authority")
    }

    private func enrolled(_ consent: ReceiptConsent) -> ReceiptEnrollment {
        ReceiptEnrollment(routeID: "route", network: "signet", identity: owner,
                          configuration: "publisher", consent: consent,
                          reference: .init(source: "credit_receive", id: "operation"),
                          eventHash: event, amountSat: 100_000, enrolledAt: 101)
    }

    private func result(state: String = "complete", amount: Int64 = 100_000,
                        created: Int64 = 101, id: String = "operation", interrupted: Bool = false,
                        needsForeground: Bool = false) throws -> ReceiptWindowResult {
        let object: [String: Any] = [
            "receipts": [["reference": ["source": "credit_receive", "id": id],
                          "canonical_id": "entry", "state": state, "amount_sat": amount,
                          "created_at_unix": created]],
            "batches": 1, "needs_foreground": needsForeground,
            "interrupted": interrupted, "budget_exhausted": false,
        ]
        return try JSONDecoder().decode(ReceiptWindowResult.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
