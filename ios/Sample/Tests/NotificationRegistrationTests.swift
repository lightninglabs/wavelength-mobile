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
}
