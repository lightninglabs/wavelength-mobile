import CryptoKit
import DeviceCheck
import Foundation
import XCTest
import WalletKit
@testable import Wavelength

private final class MemoryNotificationCredentials: NotificationCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ data: Data, account: String) throws { lock.lock(); defer { lock.unlock() }; value = data }
}

private struct FixtureNotificationAttester: NotificationAttesting {
    var supported = true
    var invalidKey: String? = nil
    let key = Data(repeating: 4, count: 32).base64EncodedString()
    func generateKey() async throws -> String { key }
    func attest(key: String, hash: Data) async throws -> Data { hash }
    func assert(key: String, hash: Data) async throws -> Data {
        if key == invalidKey { throw DCError(.invalidKey) }
        return hash
    }
}

private final class RotatingNotificationAttester: NotificationAttesting, @unchecked Sendable {
    let supported = true
    private let lock = NSLock()
    private var count = 0
    var generations: Int { lock.lock(); defer { lock.unlock() }; return count }
    private func nextKey() -> String {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return Data(repeating: UInt8(count + 1), count: 32).base64EncodedString()
    }
    func generateKey() async throws -> String { nextKey() }
    func attest(key: String, hash: Data) async throws -> Data { hash }
    func assert(key: String, hash: Data) async throws -> Data { hash }
}

private final class NotificationURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                                 httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class NotificationRelayTests: XCTestCase {
    private static func offer(id: String = "AAECAwQFBgcICQoLDA0ODw") -> NotificationFeedOffer {
        NotificationFeedOffer(sourceId: "swap", role: "swap_server",
                              sourcePubkey: "02" + String(repeating: "01", count: 32),
                              subscriberPubkey: "03" + String(repeating: "02", count: 32),
                              grantId: id, eventClasses: 3, expiresAtUnix: 2_000_000_000,
                              subscriberSignature: Data(repeating: 0, count: 64).base64EncodedString()
                                .replacingOccurrences(of: "=", with: ""))
    }

    private static func offerJSON(id: String) -> [String: Any] {
        let value = offer(id: id)
        return ["source_id": value.sourceId, "role": value.role, "source_pubkey": value.sourcePubkey,
                "subscriber_pubkey": value.subscriberPubkey, "grant_id": value.grantId,
                "event_classes": value.eventClasses, "expires_at_unix": value.expiresAtUnix,
                "subscriber_signature": value.subscriberSignature]
    }

    private func configuration() throws -> NotificationRelayConfiguration {
        try XCTUnwrap(.init(origin: "https://relay.invalid", appAlias: "test",
                            swapIssuer: "02" + String(repeating: "01", count: 32)))
    }

    @MainActor
    func testLockedRevocationRetainsProducerRetryAfterRelayAcknowledges() async throws {
        enum Offline: Error { case producer }
        var route = WalletNotificationRoute(id: "route", network: "signet", identity: "wallet",
                                            relay: try configuration(), source: .swapServer)
        route.subscriptionID = "signed-grant"
        var calls: [String] = []
        var retained = true
        do {
            let complete = try await route.revoke(currentNetwork: "signet", currentIdentity: "wallet") {
                calls.append("relay")
            } producer: { _ in
                calls.append("producer")
                throw Offline.producer
            }
            retained = !complete
        } catch Offline.producer { }
        XCTAssertTrue(retained)
        // A foreground retry may run before Face ID unlock. Relay revocation
        // must still happen, but it cannot erase the deferred producer cleanup.
        let lockedComplete = try await route.revoke(currentNetwork: "signet", currentIdentity: nil) {
            calls.append("relay")
        } producer: { _ in XCTFail("Locked wallet reached the producer") }
        retained = !lockedComplete
        XCTAssertTrue(retained)
        let complete = try await route.revoke(currentNetwork: "signet", currentIdentity: "wallet") {
            calls.append("relay")
        } producer: { id in
            XCTAssertEqual(id, "signed-grant")
            calls.append("producer")
        }
        retained = !complete
        XCTAssertFalse(retained)
        XCTAssertEqual(calls, ["relay", "producer", "relay", "relay", "producer"])
    }

    @MainActor
    func testRevocationWaitsForMatchingWalletButDropsUnboundRoute() async throws {
        var route = WalletNotificationRoute(id: "route", network: "signet", identity: "wallet",
                                            relay: try configuration(), source: .swapServer)
        route.subscriptionID = "signed-grant"
        for (network, identity) in [("mainnet", "wallet"), ("signet", "other-wallet")] {
            var revoked = false
            let complete = try await route.revoke(currentNetwork: network, currentIdentity: identity) {
                revoked = true
            } producer: { _ in XCTFail("Wrong wallet reached producer removal") }
            XCTAssertFalse(complete, "Keep bound metadata without blocking other route setup")
            XCTAssertTrue(revoked, "Device delivery must stop immediately")
        }
        // Consent can disappear after subscribe but before source binding.
        // A genuinely unbound route needs only its relay revocation.
        route.subscriptionID = nil
        var revoked = false
        let complete = try await route.revoke(currentNetwork: "signet", currentIdentity: nil) {
            revoked = true
        } producer: { _ in XCTFail("No producer grant exists") }
        XCTAssertTrue(complete)
        XCTAssertTrue(revoked)
    }

    @MainActor
    func testRevocationTriesBothOwnersDuringAnOutage() async throws {
        enum Unavailable: Error { case producer, relay }
        var calls: [String] = []
        do {
            try await WalletNotificationRoute.revoke {
                calls.append("relay")
            } producer: {
                calls.append("producer")
                throw Unavailable.producer
            }
            XCTFail("Keep the route for producer cleanup retry")
        } catch Unavailable.producer { }
        XCTAssertEqual(calls, ["relay", "producer"])
        calls = []
        do {
            try await WalletNotificationRoute.revoke {
                calls.append("relay")
                throw Unavailable.relay
            } producer: {
                calls.append("producer")
            }
            XCTFail("Keep the route for relay revoke retry")
        } catch Unavailable.relay { }
        XCTAssertEqual(calls, ["relay", "producer"])
    }

    @MainActor
    func testRevocationContinuesAfterOneRouteFails() async throws {
        enum Unavailable: Error { case producer }
        let config = try configuration()
        let routes = [NotificationSource.arkOperator, .swapServer].map {
            WalletNotificationRoute(id: $0.rawValue, network: "signet", identity: "wallet", relay: config, source: $0)
        }
        var revoked: [String] = []
        do {
            try await WalletNotificationRoute.revokeAll(routes) { route in
                try await WalletNotificationRoute.revoke {
                    revoked.append(route.id)
                } producer: {
                    if route.source == .arkOperator { throw Unavailable.producer }
                }
            }
            XCTFail("The first route still needs producer cleanup")
        } catch Unavailable.producer { }
        XCTAssertEqual(revoked, ["operator", "swap_server"], "Every relay revoke runs despite a producer outage")
    }

    func testShortPublisherOfferRefreshesCachedGrant() async throws {
        let credentials = MemoryNotificationCredentials()
        let attester = FixtureNotificationAttester()
        let old = Self.offer()
        let short = NotificationFeedOffer(sourceId: old.sourceId, role: old.role, sourcePubkey: old.sourcePubkey,
                                          subscriberPubkey: old.subscriberPubkey, grantId: old.grantId,
                                          eventClasses: old.eventClasses,
                                          expiresAtUnix: Int64(Date().timeIntervalSince1970) + 3600,
                                          subscriberSignature: old.subscriberSignature)
        let grant = NotificationRelayGrant(subscriptionId: old.grantId, feedOffers: [short],
                                           expiresAt: 2_000_000_000, alerts: true)
        try credentials.save(JSONEncoder().encode(NotificationInstallation(
            keyId: attester.key, installationId: "installation", confirmed: true,
            token: "abcd", grants: ["route": grant]
        )), account: "")
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [NotificationURLProtocol.self]
        let session = URLSession(configuration: settings)
        defer { NotificationURLProtocol.handler = nil; session.invalidateAndCancel() }
        var subscriptions = 0
        NotificationURLProtocol.handler = { request in
            if request.url!.path == "/v1/challenges" {
                return (200, try JSONSerialization.data(withJSONObject: [
                    "id": "challenge", "nonce": "nonce", "app_id": "test", "operation": "manage",
                    "installation_id": "installation", "expires_at": 2_000_000_000,
                ]))
            }
            subscriptions += 1
            return (200, try JSONSerialization.data(withJSONObject: [
                "subscription_id": old.grantId, "expires_at": 2_000_000_000,
                "feed_offers": [Self.offerJSON(id: old.grantId)],
            ]))
        }
        let client = NotificationRelayClient(configuration: try configuration(), attester: attester,
                                             session: session, credentials: credentials)
        let renewed = try await client.subscribe(token: "abcd", routeId: "route", alerts: true)
        XCTAssertEqual(subscriptions, 1, "Refresh publisher consent before re-signing a short offer")
        XCTAssertEqual(renewed.feedOffers.first?.expiresAtUnix, old.expiresAtUnix)
    }

    func testBindingRenewalUsesProducerExpiry() throws {
        let grant = NotificationRelayGrant(subscriptionId: "AAECAwQFBgcICQoLDA0ODw", feedOffers: [Self.offer()],
                                           expiresAt: 2_000_000_000, alerts: true)
        var route = WalletNotificationRoute(id: "route", network: "signet", identity: "wallet",
                                             relay: try configuration(), source: .swapServer,
                                             boundGrant: WalletNotificationRoute.fingerprint(grant))
        route.boundExpiresAt = 100_000
        XCTAssertTrue(route.isBound(grant, now: 10_000))
        XCTAssertFalse(route.isBound(grant, now: 20_000), "Renew before the producer token expires")
        route.boundExpiresAt = nil
        XCTAssertFalse(route.isBound(grant, now: 10_000), "A missing token expiry is not a live binding")
    }

    func testProofTranscriptMatchesRelayGoldenVector() throws {
        let challenge = NotificationRelayChallenge(id: "challenge", nonce: "nonce", appId: "test",
                                                    operation: "manage", installationId: "install", expiresAt: 2_000_000_000)
        let payload = Data("{\"action\":\"rotate_token\",\"device_token\":\"abcd\"}".utf8)
        let expected = "wavelength.notification-relay.v1\nmanage\ntest\ninstall\nchallenge\nnonce\n" +
            NotificationRelayConfiguration.digest(payload) + "\n"
        XCTAssertEqual(challenge.clientDataHash(payload: payload), Data(SHA256.hash(data: Data(expected.utf8))))
        XCTAssertEqual(challenge.clientDataHash(payload: payload).map { String(format: "%02x", $0) }.joined(), "a93e28326588975a56bc4513cb5598da2901bcec30b2c2b7480dad77f6cff2df")
        XCTAssertNotEqual(challenge.clientDataHash(payload: payload), challenge.clientDataHash(payload: payload + Data(" ".utf8)))
    }

    func testRejectsUntrustedConfigurationAndPushRouting() throws {
        for origin in ["http://relay.invalid", "https://user@relay.invalid", "https://relay.invalid/path", "https://relay.invalid?q=x"] {
            XCTAssertNil(NotificationRelayConfiguration(origin: origin, appAlias: "test",
                                                       swapIssuer: "02" + String(repeating: "01", count: 32)))
        }
        XCTAssertNil(WalletNotificationRoute.parsePush(["wavelength": ["version": true, "route_id": "known"]]))
        XCTAssertNil(WalletNotificationRoute.parsePush(["wavelength": ["version": 2, "route_id": "known"]]))
        XCTAssertNil(WalletNotificationRoute.parsePush(["wavelength": ["version": 1, "route_id": "https://evil.invalid"]]))
        XCTAssertEqual(WalletNotificationRoute.parsePush(["wavelength": ["version": 1, "route_id": "local-route", "amount": 100_000,
                                                                                       "url": "https://evil.invalid"]]), "local-route")
    }

    func testReinstallReplacesOnlyAppleInvalidKeyAndRetainsOldSubscriptionForRemoval() async throws {
        let configuration = try configuration()
        let credentials = MemoryNotificationCredentials()
        let routeID = WalletNotificationRoute.routeID(network: "signet", identity: "wallet", relay: configuration, source: .swapServer)
        // No UserDefaults route survives. A restored matching wallet derives
        // the same opaque route; other networks/identities/sources cannot.
        XCTAssertEqual(routeID, WalletNotificationRoute.routeID(network: "signet", identity: "wallet", relay: configuration, source: .swapServer))
        XCTAssertNotEqual(routeID, WalletNotificationRoute.routeID(network: "mainnet", identity: "wallet", relay: configuration, source: .swapServer))
        XCTAssertNotEqual(routeID, WalletNotificationRoute.routeID(network: "signet", identity: "other", relay: configuration, source: .swapServer))
        XCTAssertNotEqual(routeID, WalletNotificationRoute.routeID(network: "signet", identity: "wallet", relay: configuration, source: .arkOperator))
        let oldGrant = NotificationRelayGrant(subscriptionId: "AAECAwQFBgcICQoLDA0ODw", feedOffers: [Self.offer()], expiresAt: 2_000_000_000, alerts: true)
        let old = NotificationInstallation(keyId: "lost-key", installationId: "old-installation", confirmed: true,
                                            token: "old-token", grants: [routeID: oldGrant])
        try credentials.save(JSONEncoder().encode(old), account: "")
        let attester = FixtureNotificationAttester(invalidKey: "lost-key")
        var identity = Data("test\0".utf8)
        identity.append(try XCTUnwrap(Data(base64Encoded: attester.key)))
        let newID = NotificationRelayConfiguration.digest(identity)
        var enrollments = 0
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [NotificationURLProtocol.self]
        let session = URLSession(configuration: settings)
        defer { NotificationURLProtocol.handler = nil; session.invalidateAndCancel() }
        NotificationURLProtocol.handler = { request in
            let object = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            var result: [String: Any] = [:]
            switch request.url!.path {
            case "/v1/challenges":
                result = ["id": "challenge", "nonce": "nonce", "app_id": "test", "operation": object["operation"]!,
                          "expires_at": Int64(Date().timeIntervalSince1970) + 300]
                result["installation_id"] = object["installation_id"]
            case "/v1/installations":
                enrollments += 1
                result = ["installation_id": newID]
            case "/v1/installations/\(newID)/manage":
                result = ["subscription_id": "EBESExQVFhcYGRobHB0eHw", "feed_offers": [Self.offerJSON(id: "EBESExQVFhcYGRobHB0eHw")], "expires_at": 2_000_000_000]
            default: XCTFail("Unexpected request: \(request.url!.path)")
            }
            return (200, try JSONSerialization.data(withJSONObject: result))
        }
        let client = NotificationRelayClient(configuration: configuration, attester: attester, session: session, credentials: credentials)
        do { try await client.revoke(routeId: routeID); XCTFail("A destroyed key cannot revoke an old grant") }
        catch NotificationRelayError.previousInstallationExpires(let expiry) { XCTAssertEqual(expiry, oldGrant.expiresAt) }
        let grant = try await client.subscribe(token: "new-token", routeId: routeID, alerts: true)
        XCTAssertEqual(enrollments, 1)
        XCTAssertEqual(grant.subscriptionId, "EBESExQVFhcYGRobHB0eHw")
        XCTAssertEqual(grant.previousSubscriptions?.map(\.id), ["AAECAwQFBgcICQoLDA0ODw"])
        let route = WalletNotificationRoute(id: routeID, network: "signet", identity: "wallet", relay: configuration, source: .swapServer,
                                            boundGrant: WalletNotificationRoute.fingerprint(oldGrant))
        XCTAssertFalse(route.isBound(grant))
        try await client.acknowledgeReplacedSubscriptions(routeId: routeID)
        let reused = try await client.subscribe(token: "new-token", routeId: routeID, alerts: true)
        XCTAssertNil(reused.previousSubscriptions)
        var bound = route
        bound.boundGrant = WalletNotificationRoute.fingerprint(reused)
        bound.boundExpiresAt = reused.expiresAt
        XCTAssertTrue(bound.isBound(reused))
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    func testLostEnrollmentResponseRecoversBeforeRequestingAnotherAttestation() async throws {
        let configuration = try configuration()
        let credentials = MemoryNotificationCredentials()
        let attester = FixtureNotificationAttester()
        var identity = Data("test\0".utf8)
        identity.append(try XCTUnwrap(Data(base64Encoded: attester.key)))
        let installation = NotificationRelayConfiguration.digest(identity)
        var enrolled = false
        var attestations = 0
        var rotates = 0
        var subscriptions = 0
        var revoked = false
        var rejectRevoke = true
        var rejectManageChallenge = false
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [NotificationURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { NotificationURLProtocol.handler = nil; session.invalidateAndCancel() }
        NotificationURLProtocol.handler = { request in
            let object = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            func json(_ value: [String: Any], _ status: Int = 200) throws -> (Int, Data) {
                (status, try JSONSerialization.data(withJSONObject: value))
            }
            switch request.url!.path {
            case "/v1/challenges":
                let operation = object["operation"] as! String
                if operation == "manage" && (!enrolled || rejectManageChallenge) { return try json([:], 401) }
                var result: [String: Any] = ["id": "challenge", "nonce": "nonce", "app_id": "test", "operation": operation,
                                           "expires_at": Int64(Date().timeIntervalSince1970) + 300]
                if operation == "manage" { result["installation_id"] = installation }
                return try json(result)
            case "/v1/installations":
                attestations += 1
                enrolled = true
                throw URLError(.networkConnectionLost)
            case "/v1/installations/\(installation)/manage":
                let payload = try XCTUnwrap(Data(base64Encoded: object["payload"] as! String))
                let mutation = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
                let challenge = NotificationRelayChallenge(id: "challenge", nonce: "nonce", appId: "test", operation: "manage",
                                                            installationId: installation, expiresAt: 0)
                XCTAssertEqual(Data(base64Encoded: object["proof"] as! String), challenge.clientDataHash(payload: payload))
                switch mutation["action"] as! String {
                case "rotate_token": rotates += 1; return try json([:])
                case "subscribe":
                    subscriptions += 1
                    return try json(["subscription_id": "ICEiIyQlJicoKSorLC0uLw", "feed_offers": [Self.offerJSON(id: "ICEiIyQlJicoKSorLC0uLw")], "expires_at": 2_000_000_000])
                case "revoke_subscription":
                    if rejectRevoke { return try json([:], 401) }
                    revoked = true
                    return try json([:])
                default: throw NotificationRelayError.invalidResponse
                }
            default: throw NotificationRelayError.invalidResponse
            }
        }
        let first = NotificationRelayClient(configuration: configuration, attester: attester, session: session, credentials: credentials)
        do { _ = try await first.subscribe(token: "abcd", routeId: "route", alerts: true); XCTFail("Expected lost response") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        // A fresh process reads the pending identity and probes its deterministic
        // ID. The relay has already committed it; re-attesting is forbidden.
        let restarted = NotificationRelayClient(configuration: configuration, attester: attester, session: session, credentials: credentials)
        let grant = try await restarted.subscribe(token: "abcd", routeId: "route", alerts: true)
        XCTAssertEqual(grant.subscriptionId, "ICEiIyQlJicoKSorLC0uLw")
        XCTAssertEqual(attestations, 1)
        XCTAssertEqual(rotates, 1)
        XCTAssertEqual(subscriptions, 1)
        let disk = try JSONDecoder().decode(NotificationInstallation.self, from: XCTUnwrap(credentials.read(account: "")))
        XCTAssertTrue(disk.confirmed)
        XCTAssertNotNil(disk.grants["route"])
        _ = try await restarted.subscribe(token: "abcd", routeId: "route", alerts: true)
        XCTAssertEqual(subscriptions, 1, "Persisted grant should be reusable")
        rejectManageChallenge = true
        do { _ = try await restarted.subscribe(token: "new-token", routeId: "route", alerts: true); XCTFail("Expected 401") }
        catch { XCTAssertEqual((error as? NotificationRelayHTTPError)?.status, 401) }
        XCTAssertEqual(attestations, 1, "HTTP authorization failures must not discard a confirmed installation")
        rejectManageChallenge = false
        do { try await restarted.revoke(routeId: "route"); XCTFail("A 401 is not revocation evidence") }
        catch { XCTAssertEqual((error as? NotificationRelayHTTPError)?.status, 401) }
        let pending = try JSONDecoder().decode(NotificationInstallation.self, from: XCTUnwrap(credentials.read(account: "")))
        XCTAssertNotNil(pending.grants["route"], "Retain authority until revocation is acknowledged")
        rejectRevoke = false
        try await restarted.revoke(routeId: "route")
        XCTAssertTrue(revoked)
        let removed = try JSONDecoder().decode(NotificationInstallation.self, from: XCTUnwrap(credentials.read(account: "")))
        XCTAssertTrue(removed.grants.isEmpty)
    }
    func testReceiptModeRequiresServerAckAndInvalidatesCachedGenericGrant() async throws {
        let configuration = try configuration()
        let credentials = MemoryNotificationCredentials()
        let attester = FixtureNotificationAttester()
        let old = NotificationRelayGrant(subscriptionId: "MDEyMzQ1Njc4OTo7PD0-Pw", feedOffers: [Self.offer(id: "MDEyMzQ1Njc4OTo7PD0-Pw")],
                                        expiresAt: 2_000_000_000, alerts: true)
        try credentials.save(JSONEncoder().encode(NotificationInstallation(
            keyId: attester.key, installationId: "install", confirmed: true,
            token: "abcd", grants: ["route": old]
        )), account: "")
        var ack = false
        var modes: [String?] = []
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [NotificationURLProtocol.self]
        let session = URLSession(configuration: settings)
        defer { NotificationURLProtocol.handler = nil; session.invalidateAndCancel() }
        NotificationURLProtocol.handler = { request in
            let object = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            var result: [String: Any]
            if request.url!.path == "/v1/challenges" {
                result = ["id": "challenge", "nonce": "nonce", "app_id": "test", "operation": "manage",
                          "installation_id": "install", "expires_at": Int64(Date().timeIntervalSince1970) + 300]
            } else {
                let payload = try XCTUnwrap(Data(base64Encoded: object["payload"] as! String))
                let mutation = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
                XCTAssertEqual(mutation["action"] as? String, "subscribe")
                modes.append(mutation["alert_presentation"] as? String)
                result = ["subscription_id": "MDEyMzQ1Njc4OTo7PD0-Pw", "feed_offers": [Self.offerJSON(id: "MDEyMzQ1Njc4OTo7PD0-Pw")], "expires_at": 2_000_000_000]
                if ack { result["alert_presentation"] = mutation["alert_presentation"] ?? "generic" }
            }
            return (200, try JSONSerialization.data(withJSONObject: result))
        }
        let client = NotificationRelayClient(configuration: configuration, attester: attester,
                                             session: session, credentials: credentials)
        _ = try await client.subscribe(token: "abcd", routeId: "route", alerts: true)
        XCTAssertTrue(modes.isEmpty, "Old generic cache remains compatible")
        do {
            _ = try await client.subscribe(token: "abcd", routeId: "route", alerts: true, receiptHints: true)
            XCTFail("Missing mode acknowledgement was accepted")
        } catch { XCTAssertTrue(error is NotificationRelayError) }
        ack = true
        let hint = try await client.subscribe(token: "abcd", routeId: "route", alerts: true, receiptHints: true)
        XCTAssertEqual(hint.presentation, "receipt_hint")
        _ = try await client.subscribe(token: "abcd", routeId: "route", alerts: true, receiptHints: true)
        XCTAssertEqual(modes.count, 2, "Matching acknowledged mode should reuse cache")
        let generic = try await client.subscribe(token: "abcd", routeId: "route", alerts: true)
        XCTAssertEqual(generic.presentation, "generic")
        XCTAssertEqual(modes.count, 3)
        XCTAssertEqual(modes[0], "receipt_hint")
        XCTAssertEqual(modes[1], "receipt_hint")
        XCTAssertNil(modes[2], "Generic hosts must remain compatible with old servers")
    }

    func testProducerTokenBindingSignsExactLocalRouteAndSource() async throws {
        let configuration = try configuration()
        let credentials = MemoryNotificationCredentials()
        let grant = NotificationRelayGrant(subscriptionId: "AAECAwQFBgcICQoLDA0ODw", feedOffers: [Self.offer()],
                                          expiresAt: 2_000_000_000, alerts: true)
        let attester = FixtureNotificationAttester()
        try credentials.save(JSONEncoder().encode(NotificationInstallation(
            keyId: attester.key, installationId: "installation", confirmed: true,
            token: "abcd", grants: ["route": grant]
        )), account: "")
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [NotificationURLProtocol.self]
        let session = URLSession(configuration: settings)
        defer { NotificationURLProtocol.handler = nil; session.invalidateAndCancel() }
        var bound = 0
        NotificationURLProtocol.handler = { request in
            let object = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            if request.url!.path == "/v1/challenges" {
                return (200, try JSONSerialization.data(withJSONObject: [
                    "id": "challenge", "nonce": "nonce", "app_id": "test", "operation": "manage",
                    "installation_id": "installation", "expires_at": 2_000_000_000,
                ]))
            }
            let payload = try XCTUnwrap(Data(base64Encoded: object["payload"] as! String))
            let mutation = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
            let challenge = NotificationRelayChallenge(id: "challenge", nonce: "nonce", appId: "test",
                                                        operation: "manage", installationId: "installation", expiresAt: 0)
            XCTAssertEqual(Data(base64Encoded: object["proof"] as! String), challenge.clientDataHash(payload: payload))
            XCTAssertEqual(mutation["action"] as? String, "bind_feed")
            XCTAssertEqual(mutation["subscription_id"] as? String, grant.subscriptionId)
            let binding = try XCTUnwrap(mutation["feed_binding"] as? [String: Any])
            XCTAssertEqual(binding["source_id"] as? String, "swap")
            XCTAssertEqual(binding["event_classes"] as? UInt32, 3)
            XCTAssertEqual(binding["feed_token"] as? String, String(repeating: "A", count: 43))
            XCTAssertEqual(binding["expires_at_unix"] as? Int64, 2_000_000_000)
            XCTAssertNil(binding["device_token"])
            bound += 1
            return (200, Data("{}".utf8))
        }
        let client = NotificationRelayClient(configuration: configuration, attester: attester,
                                             session: session, credentials: credentials)
        _ = try await client.subscribe(token: "abcd", routeId: "route", alerts: true)
        let resultJSON = #"{"grant_id":"AAECAwQFBgcICQoLDA0ODw","feed_token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at_unix":2000000000}"#
        let result = try JSONDecoder().decode(NotificationFeedGrantResult.self, from: Data(resultJSON.utf8))
        try await client.bind(grant: grant, offer: grant.offer(for: .swapServer), result: result)
        XCTAssertEqual(bound, 1)
        let foreign = try JSONDecoder().decode(NotificationFeedGrantResult.self,
            from: Data(resultJSON.replacingOccurrences(of: "AAECAwQFBgcICQoLDA0ODw", with: "foreign-route").utf8))
        do {
            try await client.bind(grant: grant, offer: grant.offer(for: .swapServer), result: foreign)
            XCTFail("A producer token for another route was bound")
        } catch { XCTAssertTrue(error is NotificationRelayError) }
        XCTAssertEqual(bound, 1)
    }

    func testRejectsPaymentOfferForOperatorRole() async throws {
        let credentials = MemoryNotificationCredentials()
        let attester = FixtureNotificationAttester()
        try credentials.save(JSONEncoder().encode(NotificationInstallation(
            keyId: attester.key, installationId: "installation", confirmed: true,
            token: "abcd", grants: [:]
        )), account: "")
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [NotificationURLProtocol.self]
        let session = URLSession(configuration: settings)
        defer { NotificationURLProtocol.handler = nil; session.invalidateAndCancel() }
        NotificationURLProtocol.handler = { request in
            if request.url!.path == "/v1/challenges" {
                return (200, try JSONSerialization.data(withJSONObject: [
                    "id": "challenge", "nonce": "nonce", "app_id": "test", "operation": "manage",
                    "installation_id": "installation", "expires_at": 2_000_000_000,
                ]))
            }
            var offer = Self.offerJSON(id: "AAECAwQFBgcICQoLDA0ODw")
            offer["role"] = NotificationSource.arkOperator.rawValue
            return (200, try JSONSerialization.data(withJSONObject: [
                "subscription_id": "AAECAwQFBgcICQoLDA0ODw", "expires_at": 2_000_000_000,
                "feed_offers": [offer],
            ]))
        }
        let client = NotificationRelayClient(configuration: try configuration(), attester: attester,
                                             session: session, credentials: credentials)
        do {
            _ = try await client.subscribe(token: "abcd", routeId: "route", alerts: true)
            XCTFail("The operator role is wake-only, including on an alerts route")
        } catch NotificationRelayError.invalidResponse { }
    }

    func testUnknownInstallationRequiresExplicitFreshKeyEnrollment() async throws {
        let configuration = try configuration()
        let credentials = MemoryNotificationCredentials()
        let oldKey = Data(repeating: 1, count: 32).base64EncodedString()
        let grant = NotificationRelayGrant(subscriptionId: "AAECAwQFBgcICQoLDA0ODw", feedOffers: [Self.offer()],
                                          expiresAt: 2_000_000_000, alerts: true)
        try credentials.save(JSONEncoder().encode(NotificationInstallation(
            keyId: oldKey, installationId: "old-installation", confirmed: true,
            token: "old-token", grants: ["route": grant]
        )), account: "")
        let attester = RotatingNotificationAttester()
        let newKey = Data(repeating: 2, count: 32).base64EncodedString()
        var identity = Data("test\0".utf8)
        identity.append(try XCTUnwrap(Data(base64Encoded: newKey)))
        let newID = NotificationRelayConfiguration.digest(identity)
        var repair = false
        var attestedKeys: [String] = []
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [NotificationURLProtocol.self]
        let session = URLSession(configuration: settings)
        defer { NotificationURLProtocol.handler = nil; session.invalidateAndCancel() }
        NotificationURLProtocol.handler = { request in
            let object = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            var value: [String: Any]
            switch request.url!.path {
            case "/v1/challenges":
                if !repair { return (401, Data("{}".utf8)) }
                value = ["id": "challenge", "nonce": "nonce", "app_id": "test",
                         "operation": object["operation"]!, "expires_at": 2_000_000_000]
                value["installation_id"] = object["installation_id"]
            case "/v1/installations":
                let key = object["key_id"] as! String
                XCTAssertEqual(key, newKey)
                XCTAssertNotEqual(key, oldKey)
                attestedKeys.append(key)
                value = ["installation_id": newID]
            case "/v1/installations/\(newID)/manage":
                value = ["subscription_id": "EBESExQVFhcYGRobHB0eHw",
                         "feed_offers": [Self.offerJSON(id: "EBESExQVFhcYGRobHB0eHw")], "expires_at": 2_000_000_000]
            default: throw NotificationRelayError.invalidResponse
            }
            return (200, try JSONSerialization.data(withJSONObject: value))
        }
        let client = NotificationRelayClient(configuration: configuration, attester: attester,
                                             session: session, credentials: credentials)
        do {
            _ = try await client.subscribe(token: "new-token", routeId: "route", alerts: true)
            XCTFail("Unknown authority was silently replaced")
        } catch { XCTAssertEqual((error as? NotificationRelayHTTPError)?.status, 401) }
        XCTAssertEqual(attester.generations, 0)
        let retained = try JSONDecoder().decode(NotificationInstallation.self,
            from: XCTUnwrap(credentials.read(account: "")))
        XCTAssertEqual(retained.keyId, oldKey)
        repair = true
        try await client.reenroll(token: "new-token")
        let replaced = try await client.subscribe(token: "new-token", routeId: "route", alerts: true)
        XCTAssertEqual(attester.generations, 1)
        XCTAssertEqual(attestedKeys, [newKey])
        XCTAssertEqual(replaced.previousSubscriptions?.map(\.id), [grant.subscriptionId])
    }

}

extension NotificationRelayTests {
    // Explicit round consent is accepted only for the operator. It never
    // grants payment-alert authority or lets another source claim urgency.
    @MainActor
    func testOperatorRoundOfferConsent() async throws {
        let config = try configuration()
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [NotificationURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { NotificationURLProtocol.handler = nil; session.invalidateAndCancel() }
        for (role, classes, accepted) in [("operator", 5, true), ("operator", 1, true),
                                           ("operator", 7, false), ("swap_server", 5, false)] {
            let credentials = MemoryNotificationCredentials()
            try credentials.save(try JSONSerialization.data(withJSONObject: [
                "keyId": Data(repeating: 4, count: 32).base64EncodedString(),
                "installationId": "install", "confirmed": true, "token": "abcd", "grants": [:]
            ]), account: "test")
            NotificationURLProtocol.handler = { request in
                let result: [String: Any]
                if request.url!.path == "/v1/challenges" {
                    result = ["id": "challenge", "nonce": "nonce", "app_id": "test",
                              "operation": "manage", "installation_id": "install",
                              "expires_at": Int64(Date().timeIntervalSince1970) + 300]
                } else {
                    var offer = Self.offerJSON(id: "MDEyMzQ1Njc4OTo7PD0-Pw")
                    offer["role"] = role
                    offer["event_classes"] = classes
                    result = ["subscription_id": "MDEyMzQ1Njc4OTo7PD0-Pw",
                              "feed_offers": [offer], "expires_at": 2_000_000_000]
                }
                return (200, try JSONSerialization.data(withJSONObject: result))
            }
            let client = NotificationRelayClient(configuration: config, attester: FixtureNotificationAttester(),
                                                 session: session, credentials: credentials)
            do {
                _ = try await client.subscribe(token: "abcd", routeId: "route", alerts: false)
                XCTAssertTrue(accepted, "Accepted forbidden round offer: \(role)/\(classes)")
            } catch {
                XCTAssertFalse(accepted, "Rejected supported round offer: \(error)")
            }
        }
    }
}
