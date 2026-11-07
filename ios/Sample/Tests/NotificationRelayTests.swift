import CryptoKit
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
    let key = Data(repeating: 4, count: 32).base64EncodedString()
    func generateKey() async throws -> String { key }
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
    private func configuration() throws -> NotificationRelayConfiguration {
        try XCTUnwrap(.init(origin: "https://relay.invalid", appAlias: "test", producerAlias: "local",
                            swapIssuer: "02" + String(repeating: "01", count: 32)))
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
            XCTAssertNil(NotificationRelayConfiguration(origin: origin, appAlias: "test", producerAlias: "local",
                                                       swapIssuer: "02" + String(repeating: "01", count: 32)))
        }
        XCTAssertNil(WalletNotificationRoute.parsePush(["wavelength": ["version": true, "route_id": "known"]]))
        XCTAssertNil(WalletNotificationRoute.parsePush(["wavelength": ["version": 2, "route_id": "known"]]))
        XCTAssertNil(WalletNotificationRoute.parsePush(["wavelength": ["version": 1, "route_id": "https://evil.invalid"]]))
        XCTAssertEqual(WalletNotificationRoute.parsePush(["wavelength": ["version": 1, "route_id": "local-route", "amount": 100_000,
                                                                                       "url": "https://evil.invalid"]]), "local-route")
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
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [NotificationURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { NotificationURLProtocol.handler = nil; session.invalidateAndCancel() }
        NotificationURLProtocol.handler = { request in
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
            }
            let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            func json(_ value: [String: Any], _ status: Int = 200) throws -> (Int, Data) {
                (status, try JSONSerialization.data(withJSONObject: value))
            }
            switch request.url!.path {
            case "/v1/challenges":
                let operation = object["operation"] as! String
                if operation == "manage" && !enrolled { return try json([:], 401) }
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
                    return try json(["subscription_id": "subscription", "wake_capability": String(repeating: "A", count: 43),
                                     "alert_capability": String(repeating: "A", count: 43), "expires_at": Int64(Date().timeIntervalSince1970) + 2_000_000])
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
        XCTAssertEqual(grant.subscriptionId, "subscription")
        XCTAssertEqual(attestations, 1)
        XCTAssertEqual(rotates, 1)
        XCTAssertEqual(subscriptions, 1)
        let disk = try JSONDecoder().decode(NotificationInstallation.self, from: XCTUnwrap(credentials.read(account: "")))
        XCTAssertTrue(disk.confirmed)
        XCTAssertNotNil(disk.grants["route"])
        _ = try await restarted.subscribe(token: "abcd", routeId: "route", alerts: true)
        XCTAssertEqual(subscriptions, 1, "Persisted grant should be reusable")
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
}
