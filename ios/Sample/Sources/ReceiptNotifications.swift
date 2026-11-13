import Foundation
import UIKit
import WalletKit

/// Synthetic public inputs have the same fixture in the producer and relay
/// document. The relay receives neither the invoice hash nor the amount.
enum ReceiptEventIdentity {
    static func relayHash(owner: String, paymentHash: String) -> String? {
        guard let key = hex(owner), key.count == 33, [2, 3].contains(key.first ?? 0),
              let hash = hex(paymentHash), hash.count == 32 else { return nil }
        let event = NotificationRelayConfiguration.digest(
            Data("wavelength.receipt-notification.v1\0".utf8) + key + hash
        )
        return NotificationRelayConfiguration.digest(Data(event.utf8))
    }

    private static func hex(_ value: String) -> Data? {
        guard value.utf8.count == value.count, value.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

/// Only the fixed payment marker permits local presentation. Visible remote
/// alerts already have a presentation; ordinary wakes carry no such authority.
struct ReceiptPaymentHint {
    let routeID: String
    let eventHash: String

    init?(userInfo: [AnyHashable: Any]) {
        guard let route = WalletNotificationRoute.parsePush(userInfo),
              let payload = userInfo["wavelength"] as? [String: Any],
              payload["kind"] as? String == "payment_activity",
              let hash = payload["event_id"] as? String, hash.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (userInfo["aps"] as? [String: Any])?["alert"] == nil else { return nil }
        routeID = route
        eventHash = hash
    }
}

struct ReceiptConsent: Codable, Equatable {
    let epoch: String
    let createdAfterUnix: Int64
}

struct ReceiptEnrollment: Codable {
    let routeID: String
    let network: String
    let identity: String
    let configuration: String
    let consent: ReceiptConsent
    let reference: LightningReceiptReference
    let eventHash: String
    let amountSat: Int64
    let enrolledAt: Int64
}

private struct ReceiptNotificationState: Codable {
    var consent: [String: ReceiptConsent] = [:]
    var enrolled: [String: ReceiptEnrollment] = [:]
    var shown: [String: Int64] = [:]
}

/// Device-only Keychain writes precede local presentation. A crash may omit an
/// alert, but cannot turn a prior generic fallback into a later amount banner.
@MainActor
final class ReceiptNotificationLedger {
    private let storage: any NotificationCredentialStorage
    private let account = "notification-receipt-presentations.v1"
    private let lifetime: Int64 = 2 * 24 * 60 * 60
    private let capacity = 1024
    private var presenting: Set<String> = []

    init(storage: any NotificationCredentialStorage = NotificationKeychainStorage()) {
        self.storage = storage
    }

    /// Own one event across awaits. An unrelated maintenance window must not
    /// suppress its generic banner, and a duplicate must not steal its proof.
    func reservePresentation(routeID: String, eventHash: String) -> Bool {
        presenting.insert(routeID + ":" + eventHash).inserted
    }

    func releasePresentation(routeID: String, eventHash: String) {
        presenting.remove(routeID + ":" + eventHash)
    }

    func consent(network: String) throws -> ReceiptConsent? {
        try load().consent[network]
    }

    @discardableResult
    func ensureConsent(network: String, now: Int64) throws -> ReceiptConsent {
        var state = try load()
        if let consent = state.consent[network] { return consent }
        let consent = ReceiptConsent(epoch: UUID().uuidString, createdAfterUnix: now)
        state.consent[network] = consent
        try save(state)
        return consent
    }

    func revoke(network: String) throws {
        var state = try load()
        state.consent.removeValue(forKey: network)
        state.enrolled = state.enrolled.filter { $0.value.network != network }
        try save(state)
    }

    func enroll(_ value: ReceiptEnrollment, now: Int64) throws {
        var state = try load()
        prune(&state, now: now)
        guard state.consent[value.network] == value.consent,
              value.reference.isSupported, value.amountSat > 0,
              state.enrolled.count < capacity else { return }
        let key = value.routeID + ":" + value.eventHash
        guard state.shown[key] == nil else { return }
        state.enrolled[key] = value
        try save(state)
    }

    func enrolled(routeID: String, eventHash: String, now: Int64) throws -> ReceiptEnrollment? {
        let state = try load()
        guard let value = state.enrolled[routeID + ":" + eventHash],
              value.enrolledAt > now - lifetime,
              state.consent[value.network] == value.consent else { return nil }
        return value
    }

    /// Commit at-most-once presentation authority before UNNotificationCenter.
    /// Storage unavailable before first unlock means no local presentation.
    func claim(routeID: String, eventHash: String, now: Int64) throws -> Bool {
        var state = try load()
        prune(&state, now: now)
        let key = routeID + ":" + eventHash
        guard state.shown[key] == nil, state.shown.count < capacity else { return false }
        state.shown[key] = now
        state.enrolled.removeValue(forKey: key)
        try save(state)
        return true
    }

    private func load() throws -> ReceiptNotificationState {
        guard let data = try storage.read(account: account) else { return .init() }
        return try JSONDecoder().decode(ReceiptNotificationState.self, from: data)
    }

    private func save(_ state: ReceiptNotificationState) throws {
        try storage.save(JSONEncoder().encode(state), account: account)
    }

    private func prune(_ state: inout ReceiptNotificationState, now: Int64) {
        state.enrolled = state.enrolled.filter { $0.value.enrolledAt > now - lifetime }
        state.shown = state.shown.filter { $0.value > now - lifetime }
    }
}

/// Amounts require native completion plus every original enrollment boundary.
/// An authorized unmatched or unfinished hint can only use the fixed fallback.
enum ReceiptNotificationPresentation {
    static let generic = "Payment activity. Open Wavelength to update your wallet."

    static func body(enrollment: ReceiptEnrollment?, result: ReceiptWindowResult?) -> String {
        guard let enrollment, let result, !result.interrupted,
              !result.needsForeground, !result.budgetExhausted,
              let proof = result.receipts.first(where: { $0.reference == enrollment.reference }),
              proof.state == "complete", !proof.canonicalID.isEmpty,
              proof.amountSat == enrollment.amountSat, proof.amountSat > 0,
              proof.createdAtUnix > enrollment.consent.createdAfterUnix else { return generic }
        return "You received \(proof.amountSat.formatted()) sats."
    }
}

/// OS completion can happen before native final access. The retained store
/// continues to own that call; expiration only signals the matching window.
@MainActor
final class ReceiptFetchLease {
    // OS expiry is primary. Leave two seconds before the documented callback
    // limit; the SDK ceiling must not cut short this host-owned opportunity.
    static let fallbackSeconds = 28
    static let nativeCeilingSeconds = 30
    private let fallbackDeadline: TimeInterval
    private let uptime: () -> TimeInterval
    private(set) var expired = false
    private(set) var finished = false
    private var completion: ((UIBackgroundFetchResult) -> Void)?
    var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(startedAt: TimeInterval? = nil,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         completion: @escaping (UIBackgroundFetchResult) -> Void) {
        self.uptime = uptime
        fallbackDeadline = (startedAt ?? uptime()) + Double(Self.fallbackSeconds)
        self.completion = completion
    }

    /// Include main-actor queueing and wallet preparation in the same deadline.
    /// Returning an OS callback never releases the native invocation's owner.
    func fallback(sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
                  onExpiry: @escaping () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            do { try await sleep(UInt64(max(0, fallbackDeadline - uptime()) * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled, !finished else { return }
            onExpiry()
        }
    }

    func expire(_ result: UIBackgroundFetchResult = .noData) {
        expired = true
        finish(result)
    }

    func finish(_ result: UIBackgroundFetchResult) {
        guard !finished else { return }
        finished = true
        completion?(result)
        completion = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
