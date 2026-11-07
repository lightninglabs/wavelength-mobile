import CryptoKit
import DeviceCheck
import Foundation

/// Publisher configuration comes from the build, never from a push payload.
struct NotificationRelayConfiguration: Equatable, Sendable, Codable {
    let origin: URL
    let appAlias: String
    let producerAlias: String
    let swapIssuer: String

    init?(origin: String, appAlias: String, producerAlias: String, swapIssuer: String) {
        guard let url = URL(string: origin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              Self.identifier(appAlias), Self.identifier(producerAlias),
              swapIssuer.count == 66, swapIssuer.hasPrefix("02") || swapIssuer.hasPrefix("03"),
              swapIssuer.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        self.origin = url
        self.appAlias = appAlias
        self.producerAlias = producerAlias
        self.swapIssuer = swapIssuer
    }

    var storageAccount: String {
        "notification-relay." + Self.digest(Data((origin.absoluteString + "\0" + appAlias).utf8))
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

struct NotificationRelayGrant: Codable, Sendable {
    let subscriptionId: String
    let wakeCapability: String
    let alertCapability: String?
    let expiresAt: Int64
    let alerts: Bool
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
}

private struct NotificationManagementResult: Decodable {
    let subscriptionId: String?
    let wakeCapability: String?
    let alertCapability: String?
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

    func subscribe(token: String, routeId: String, alerts: Bool) async throws -> NotificationRelayGrant {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard attester.supported else { throw NotificationRelayError.unsupportedDevice }
        try await ensureInstallation(token: token)
        guard let current = installation else { throw NotificationRelayError.unavailableCredentials }
        if let grant = current.grants[routeId], grant.alerts == alerts,
           grant.expiresAt > Int64(Date().timeIntervalSince1970) + 86_400 {
            return grant
        }
        let result = try await manage([
            "action": "subscribe", "route_id": routeId, "enable_alerts": alerts,
        ])
        guard let id = result.subscriptionId, NotificationRelayConfiguration.identifier(id),
              let wake = result.wakeCapability, Self.validCapability(wake),
              let expiry = result.expiresAt, expiry > Int64(Date().timeIntervalSince1970),
              !alerts || result.alertCapability.map(Self.validCapability) == true else {
            throw NotificationRelayError.invalidResponse
        }
        let grant = NotificationRelayGrant(subscriptionId: id, wakeCapability: wake,
                                          alertCapability: result.alertCapability,
                                          expiresAt: expiry, alerts: alerts)
        var saved = try requireInstallation()
        saved.grants[routeId] = grant
        try save(saved)
        return grant
    }

    func revoke(routeId: String) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try load()
        guard let grant = installation?.grants[routeId] else { return }
        do {
            _ = try await manage(["action": "revoke_subscription", "subscription_id": grant.subscriptionId])
        } catch let error as NotificationRelayHTTPError where error.status == 404 {
            // An absent grant is already unable to authorize another delivery.
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
        let key = try await attester.generateKey()
        guard let decoded = Data(base64Encoded: key), decoded.count == 32 else {
            throw NotificationRelayError.invalidResponse
        }
        var identity = Data(configuration.appAlias.utf8)
        identity.append(0)
        identity.append(decoded)
        let id = NotificationRelayConfiguration.digest(identity)
        try save(NotificationInstallation(keyId: key, installationId: id,
                                          confirmed: false, token: "", grants: [:]))
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

    private static func validCapability(_ value: String) -> Bool {
        guard value.count == 43 else { return false }
        let padded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        return Data(base64Encoded: padded)?.count == 32
    }
}
