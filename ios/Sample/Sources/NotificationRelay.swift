import CryptoKit
import DeviceCheck
import Foundation
import WalletKit

/// Publisher configuration comes from the build, never from a push payload.
struct NotificationRelayConfiguration: Equatable, Sendable, Codable {
    let origin: URL
    let appAlias: String
    let swapIssuer: String
    let receiptHints: Bool?

    init?(origin: String, appAlias: String, swapIssuer: String, receiptHints: Bool = false) {
        guard let url = URL(string: origin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              Self.identifier(appAlias),
              swapIssuer.count == 66, swapIssuer.hasPrefix("02") || swapIssuer.hasPrefix("03"),
              swapIssuer.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        self.origin = url
        self.appAlias = appAlias
        self.swapIssuer = swapIssuer
        self.receiptHints = receiptHints ? true : nil
    }

    var storageAccount: String {
        "notification-relay.feed-v1." + Self.digest(Data((origin.absoluteString + "\0" + appAlias).utf8))
    }

    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct NotificationPreviousSubscription: Codable, Sendable {
    let id: String
    let expiresAt: Int64
}

struct NotificationFeedOffer: Codable, Sendable {
    let sourceId: String
    let role: String
    let sourcePubkey: String
    let subscriberPubkey: String
    let grantId: String
    let eventClasses: UInt32
    let expiresAtUnix: Int64
    let subscriberSignature: String
}

struct NotificationRelayGrant: Codable, Sendable {
    var previousSubscriptions: [NotificationPreviousSubscription]? = nil
    let subscriptionId: String
    let feedOffers: [NotificationFeedOffer]
    let expiresAt: Int64
    let alerts: Bool
    var presentation: String? = nil

    /// Cache renewal must honor the shortest publisher offer as well as the
    /// local grant. Re-signing cannot extend an expired offer's consent.
    var renewalExpiresAt: Int64 {
        min(expiresAt, feedOffers.map(\.expiresAtUnix).min() ?? 0)
    }

    /// Roles select only configured native sources. Their actual issuer and
    /// publisher consent are checked by the native signer before delegation.
    func offer(for source: NotificationSource) throws -> NotificationFeedOffer {
        let matches = feedOffers.filter { $0.role == source.rawValue }
        guard matches.count == 1 else { throw NotificationRelayError.invalidResponse }
        return matches[0]
    }
}

struct NotificationRelayChallenge: Decodable, Sendable {
    let id: String
    let nonce: String
    let appId: String
    let operation: String
    let installationId: String?
    let expiresAt: Int64

    /// Hash the exact bytes carried in payload, including the final newline.
    func clientDataHash(payload: Data) -> Data {
        let fields = [
            "wavelength.notification-relay.v1", operation, appId,
            installationId ?? "", id, nonce,
            NotificationRelayConfiguration.digest(payload), "",
        ]
        return Data(SHA256.hash(data: Data(fields.joined(separator: "\n").utf8)))
    }
}

struct NotificationRelayHTTPError: Error {
    let status: Int
}

enum NotificationRelayError: Error {
    case unsupportedDevice, invalidResponse, unavailableCredentials
    case previousInstallationExpires(Int64)
}

/// This adapter has no runtime bypass. Tests may inject a protocol fixture;
/// the actual relay still requires Apple's attestation chain and assertions.
protocol NotificationAttesting: Sendable {
    var supported: Bool { get }
    func generateKey() async throws -> String
    func attest(key: String, hash: Data) async throws -> Data
    func assert(key: String, hash: Data) async throws -> Data
}

struct DeviceNotificationAttester: NotificationAttesting {
    var supported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateKey { key, error in
                if let error { continuation.resume(throwing: error) }
                else if let key { continuation.resume(returning: key) }
                else { continuation.resume(throwing: NotificationRelayError.invalidResponse) }
            }
        }
    }

    func attest(key: String, hash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.attestKey(key, clientDataHash: hash) { proof, error in
                if let error { continuation.resume(throwing: error) }
                else if let proof { continuation.resume(returning: proof) }
                else { continuation.resume(throwing: NotificationRelayError.invalidResponse) }
            }
        }
    }

    func assert(key: String, hash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateAssertion(key, clientDataHash: hash) { proof, error in
                if let error { continuation.resume(throwing: error) }
                else if let proof { continuation.resume(returning: proof) }
                else { continuation.resume(throwing: NotificationRelayError.invalidResponse) }
            }
        }
    }
}

private final class RejectRelayRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct NotificationInstallation: Codable {
    let keyId: String
    let installationId: String
    var confirmed: Bool
    var token: String
    var grants: [String: NotificationRelayGrant]
    var retired: [String: [NotificationPreviousSubscription]]? = nil
}

private struct NotificationManagementResult: Decodable {
    let alertPresentation: String?
    let subscriptionId: String?
    let feedOffers: [NotificationFeedOffer]?
    let expiresAt: Int64?
}

private struct NotificationEnrollmentResult: Decodable {
    let installationId: String
}

/// Grant credentials are stored separately from wallet signing secrets.
protocol NotificationCredentialStorage: Sendable {
    func read(account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
}

struct NotificationKeychainStorage: NotificationCredentialStorage {
    func read(account: String) throws -> Data? { try KeychainStore.read(account: account) }
    func save(_ data: Data, account: String) throws { try KeychainStore.save(data, account: account) }
}

/// One installation owns all assertions. Actor reentrancy alone cannot order
/// counters across network awaits, so the operation gate spans each full proof.
actor NotificationRelayClient {
    let configuration: NotificationRelayConfiguration
    private let attester: any NotificationAttesting
    private let session: URLSession
    private let credentials: any NotificationCredentialStorage
    private var installation: NotificationInstallation?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: NotificationRelayConfiguration,
         attester: any NotificationAttesting = DeviceNotificationAttester(),
         session: URLSession? = nil,
         credentials: any NotificationCredentialStorage = NotificationKeychainStorage()) {
        self.credentials = credentials
        self.configuration = configuration
        self.attester = attester
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 10
        settings.timeoutIntervalForResource = 15
        self.session = session ?? URLSession(configuration: settings, delegate: RejectRelayRedirects(), delegateQueue: nil)
    }

    func subscribe(token: String, routeId: String, alerts: Bool, receiptHints: Bool = false) async throws -> NotificationRelayGrant {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard attester.supported else { throw NotificationRelayError.unsupportedDevice }
        do {
            return try await subscribeLocked(token: token, routeId: routeId, alerts: alerts, receiptHints: receiptHints)
        } catch let error as DCError where error.code == .invalidKey {
            // Apple destroys App Attest keys on uninstall while Keychain can
            // survive. Only this precise device error permits replacement;
            // an HTTP 401 or transient attestation error retains authority.
            var retired = installation?.retired ?? [:]
            for (route, grant) in installation?.grants ?? [:] {
                retired[route, default: []].append(.init(id: grant.subscriptionId, expiresAt: grant.expiresAt))
            }
            try await enroll(token: token, retired: retired)
            return try await subscribeLocked(token: token, routeId: routeId, alerts: alerts, receiptHints: receiptHints)
        }
    }

    private func subscribeLocked(token: String, routeId: String, alerts: Bool, receiptHints: Bool) async throws -> NotificationRelayGrant {
        try await ensureInstallation(token: token)
        guard let current = installation else { throw NotificationRelayError.unavailableCredentials }
        let presentation = alerts && receiptHints ? "receipt_hint" : "generic"
        if let grant = current.grants[routeId], grant.alerts == alerts,
           (grant.presentation ?? "generic") == presentation,
           grant.renewalExpiresAt > Int64(Date().timeIntervalSince1970) + 86_400 {
            return grant
        }
        var payload: [String: Any] = [
            "action": "subscribe", "route_id": routeId, "enable_alerts": alerts,
        ]
        // Old servers reject this field. Never assume local presentation
        // replaced their visible alert without an explicit acknowledgement.
        if alerts && receiptHints { payload["alert_presentation"] = presentation }
        let result = try await manage(payload)
        guard let id = result.subscriptionId, NotificationRelayConfiguration.identifier(id),
              let offers = result.feedOffers, !offers.isEmpty, offers.count <= 16,
              let expiry = result.expiresAt, expiry > Int64(Date().timeIntervalSince1970),
              presentation != "receipt_hint" || result.alertPresentation == "receipt_hint" else {
            throw NotificationRelayError.invalidResponse
        }
        guard Set(offers.map(\.sourceId)).count == offers.count,
              offers.allSatisfy({ Self.validOffer($0, subscription: id, expiry: expiry, alerts: alerts) }) else {
            throw NotificationRelayError.invalidResponse
        }
        let grant = NotificationRelayGrant(previousSubscriptions: current.retired?[routeId], subscriptionId: id,
                                          feedOffers: offers, expiresAt: expiry, alerts: alerts,
                                          presentation: result.alertPresentation)
        var saved = try requireInstallation()
        saved.grants[routeId] = grant
        try save(saved)
        return grant
    }

    /// The installation signs the local subscription and exact producer token.
    /// A token is correlation only and cannot select another local destination.
    func bind(grant: NotificationRelayGrant, offer: NotificationFeedOffer,
              result: NotificationFeedGrantResult) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard grant.subscriptionId == offer.grantId, result.grantID == offer.grantId,
              Self.validBase64URL(result.feedToken, bytes: 32),
              result.expiresAtUnix > Int64(Date().timeIntervalSince1970),
              result.expiresAtUnix <= offer.expiresAtUnix else { throw NotificationRelayError.invalidResponse }
        _ = try await manage([
            "action": "bind_feed", "subscription_id": grant.subscriptionId,
            "feed_binding": ["source_id": offer.sourceId, "feed_token": result.feedToken,
                             "event_classes": offer.eventClasses, "expires_at_unix": result.expiresAtUnix],
        ])
    }

    /// Explicit repair creates a fresh Apple key. A 401 alone is not proof
    /// that old authority disappeared and never triggers automatic replacement.
    func reenroll(token: String) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try load()
        var retired = installation?.retired ?? [:]
        for (route, grant) in installation?.grants ?? [:] {
            retired[route, default: []].append(.init(id: grant.subscriptionId, expiresAt: grant.expiresAt))
        }
        try await enroll(token: token, retired: retired)
    }

    func acknowledgeReplacedSubscriptions(routeId: String) throws {
        var saved = try requireInstallation()
        saved.retired?.removeValue(forKey: routeId)
        saved.grants[routeId]?.previousSubscriptions = nil
        try save(saved)
    }

    func revoke(routeId: String) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try load()
        let now = Int64(Date().timeIntervalSince1970)
        if let retired = installation?.retired?[routeId], let expiry = retired.map(\.expiresAt).max(), expiry > now {
            throw NotificationRelayError.previousInstallationExpires(expiry)
        }
        guard let grant = installation?.grants[routeId] else { return }
        if grant.expiresAt <= now {
            var saved = try requireInstallation()
            saved.grants.removeValue(forKey: routeId)
            try save(saved)
            return
        }
        do {
            _ = try await manage(["action": "revoke_subscription", "subscription_id": grant.subscriptionId])
        } catch let error as NotificationRelayHTTPError where error.status == 404 {
            // An absent grant is already unable to authorize another delivery.
        } catch let error as DCError where error.code == .invalidKey {
            throw NotificationRelayError.previousInstallationExpires(grant.expiresAt)
        }
        var saved = try requireInstallation()
        saved.grants.removeValue(forKey: routeId)
        try save(saved)
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }

    private func load() throws {
        guard installation == nil,
              let data = try credentials.read(account: configuration.storageAccount) else { return }
        installation = try JSONDecoder().decode(NotificationInstallation.self, from: data)
    }

    private func save(_ value: NotificationInstallation) throws {
        try credentials.save(JSONEncoder().encode(value), account: configuration.storageAccount)
        installation = value
    }

    private func requireInstallation() throws -> NotificationInstallation {
        guard let installation else { throw NotificationRelayError.unavailableCredentials }
        return installation
    }

    private func ensureInstallation(token: String) async throws {
        try load()
        if let current = installation {
            if current.confirmed && current.token == token { return }
            do {
                _ = try await manage(["action": "rotate_token", "device_token": token])
                var recovered = try requireInstallation()
                recovered.confirmed = true
                recovered.token = token
                try save(recovered)
                return
            } catch let error as NotificationRelayHTTPError where error.status == 401 && !current.confirmed {
                // Enrollment may have committed despite a lost response. Probe
                // its deterministic ID before creating another attestation key.
                // Confirmed installations never discard authority on a 401.
            }
        }
        try await enroll(token: token, retired: installation?.retired ?? [:])
    }

    private func enroll(token: String, retired: [String: [NotificationPreviousSubscription]]) async throws {
        let key = try await attester.generateKey()
        guard let decoded = Data(base64Encoded: key), decoded.count == 32 else {
            throw NotificationRelayError.invalidResponse
        }
        var identity = Data(configuration.appAlias.utf8)
        identity.append(0)
        identity.append(decoded)
        let id = NotificationRelayConfiguration.digest(identity)
        try save(NotificationInstallation(keyId: key, installationId: id,
                                          confirmed: false, token: "", grants: [:], retired: retired))
        let challenge = try await challenge(operation: "enroll", installationId: nil)
        let payload = try JSONSerialization.data(withJSONObject: ["device_token": token], options: [.sortedKeys])
        let proof = try await attester.attest(key: key, hash: challenge.clientDataHash(payload: payload))
        let result: NotificationEnrollmentResult = try await post("/v1/installations", object: [
            "challenge_id": challenge.id, "key_id": key,
            "proof": proof.base64EncodedString(), "payload": payload.base64EncodedString(),
        ])
        guard result.installationId == id else { throw NotificationRelayError.invalidResponse }
        var confirmed = try requireInstallation()
        confirmed.confirmed = true
        confirmed.token = token
        try save(confirmed)
    }

    private func challenge(operation: String, installationId: String?) async throws -> NotificationRelayChallenge {
        var request: [String: Any] = ["app_id": configuration.appAlias, "operation": operation]
        if let installationId { request["installation_id"] = installationId }
        let value: NotificationRelayChallenge = try await post("/v1/challenges", object: request)
        guard value.appId == configuration.appAlias, value.operation == operation,
              value.installationId == installationId,
              value.expiresAt > Int64(Date().timeIntervalSince1970),
              [value.id, value.nonce].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("\n") }) else {
            throw NotificationRelayError.invalidResponse
        }
        return value
    }

    private func manage(_ object: [String: Any]) async throws -> NotificationManagementResult {
        let current = try requireInstallation()
        let challenge = try await challenge(operation: "manage", installationId: current.installationId)
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let proof = try await attester.assert(key: current.keyId, hash: challenge.clientDataHash(payload: payload))
        return try await post("/v1/installations/\(current.installationId)/manage", object: [
            "challenge_id": challenge.id, "proof": proof.base64EncodedString(),
            "payload": payload.base64EncodedString(),
        ])
    }

    private func post<T: Decodable>(_ path: String, object: [String: Any]) async throws -> T {
        var request = URLRequest(url: configuration.origin.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotificationRelayError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw NotificationRelayHTTPError(status: http.statusCode) }
        guard data.count <= 65_536 else { throw NotificationRelayError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private static func validBase64URL(_ value: String, bytes: Int) -> Bool {
        guard !value.contains("="), value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || [45, 95].contains($0)
        }) else { return false }
        let padded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded), decoded.count == bytes else { return false }
        let canonical = decoded.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return canonical == value
    }

    private static func validOffer(_ offer: NotificationFeedOffer, subscription: String,
                                   expiry: Int64, alerts: Bool) -> Bool {
        func publicKey(_ value: String) -> Bool {
            value.count == 66 && (value.hasPrefix("02") || value.hasPrefix("03")) &&
                value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        return NotificationRelayConfiguration.identifier(offer.sourceId) &&
            NotificationRelayConfiguration.identifier(offer.role) &&
            publicKey(offer.sourcePubkey) && publicKey(offer.subscriberPubkey) &&
            offer.grantId == subscription && (22...64).contains(offer.grantId.count) &&
            offer.eventClasses > 0 && offer.eventClasses & ~UInt32(3) == 0 &&
            (alerts || offer.eventClasses & 2 == 0) &&
            (offer.role != NotificationSource.arkOperator.rawValue || offer.eventClasses == 1) &&
            offer.expiresAtUnix > Int64(Date().timeIntervalSince1970) && offer.expiresAtUnix <= expiry &&
            validBase64URL(offer.subscriberSignature, bytes: 64)
    }
}
