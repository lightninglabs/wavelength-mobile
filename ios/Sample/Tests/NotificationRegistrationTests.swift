import XCTest
@testable import WalletKit

final class NotificationRegistrationTests: XCTestCase {
    func testRemovalDropsAllProducerCredentials() throws {
        let request = NotificationSubscription.remove(source: .swapServer, subscriptionID: "route")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["source", "subscription_id", "remove"])
        XCTAssertEqual(object["source"] as? String, "swap_server")
        XCTAssertEqual(object["remove"] as? Bool, true)
    }

    func testIssuerPinIsExplicitAndUsesNativeConfigKey() throws {
        var config = WalletConfig.signet(dataDir: "/tmp/notification-registration-test")
        let unset = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertNil(unset["swap_notification_issuer"])
        let publicKey = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        config.swapNotificationIssuer = publicKey
        let pinned = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertEqual(pinned["swap_notification_issuer"] as? String, publicKey)
    }

    func testPendingStopRequiresNativeOwnershipEvidence() {
        XCTAssertTrue(WalletError(message: "wavewalletdk mobile stop pending; call Stop again: context deadline exceeded").isStopPending)
        XCTAssertFalse(WalletError(message: "context deadline exceeded").isStopPending)
    }

    func testNativeSourceRegistrationRejectsUnstartedClient() async {
        let client = WalletClient()
        do {
            _ = try await client.setNotificationSubscription(.remove(source: .arkOperator, subscriptionID: "route"))
            XCTFail("An unstarted native singleton accepted source registration")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not started"))
        }
    }
    func testDiagnosticsRedactBothCapabilities() {
        let request = NotificationSubscription.register(
            source: .swapServer, subscriptionID: "route", relayID: "app",
            wakeCapability: "synthetic-wake-secret", alertCapability: "synthetic-alert-secret",
            expiresAtUnix: 2_000_000_000
        )
        for description in [String(describing: request), String(reflecting: request)] {
            XCTAssertFalse(description.contains("synthetic-wake-secret"))
            XCTAssertFalse(description.contains("synthetic-alert-secret"))
        }
        XCTAssertEqual(Set(request.customMirror.children.compactMap(\.label)), ["source", "subscriptionID", "remove"])
    }

    func testNativeRegistrationAndRemovalResultFixtures() throws {
        // Produced with encoding/json from the pinned SDK facade DTO. The
        // gomobile method uses that encoder, not protojson, including zero.
        let fixtures = [
            (#"{"subscription_id":"route","expires_at_unix":2000000000}"#, Int64(2_000_000_000)),
            (#"{"subscription_id":"route","expires_at_unix":0}"#, Int64(0)),
        ]
        for (json, expiry) in fixtures {
            let value = try JSONDecoder().decode(NotificationSubscriptionResult.self, from: Data(json.utf8))
            XCTAssertEqual(value.subscriptionID, "route")
            XCTAssertEqual(value.expiresAtUnix, expiry)
        }
    }

}
