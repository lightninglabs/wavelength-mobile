import Foundation
import WalletKit

/// Trusted local admission, separate from optional banner/amount consent.
/// A Lightning source ID may itself be a payment hash. No amount, invoice or
/// push payload is stored here, and these references never go to the relay.
struct ReceiveWorkEnrollment: Codable, Equatable {
    let network: String
    let identity: String
    let reference: LightningReceiptReference
    let canonicalID: String?

    var key: String {
        [network, identity, reference.source, reference.id].joined(separator: "\0")
    }
}

private struct ReceiveWorkState: Codable {
    var enrolled: [String: ReceiveWorkEnrollment] = [:]
    var cursors: [String: String] = [:]
    var importedPresentations = false
}

/// Retain every unresolved admission. Sixty-four bounds one native invocation,
/// not storage. Persisted cursors prevent older admissions starving newer ones.
@MainActor
final class ReceiveWorkLedger {
    private let storage: any NotificationCredentialStorage
    private let account = "notification-receive-work.v1"

    init(storage: any NotificationCredentialStorage = NotificationKeychainStorage()) {
        self.storage = storage
    }

    func enroll(_ values: [ReceiveWorkEnrollment]) throws {
        var state = try load()
        var changed = false
        for value in values where value.reference.isSupported &&
            !value.network.isEmpty && !value.identity.isEmpty {
            // Migration must not replace a newer admission's canonical ID.
            if state.enrolled[value.key] == nil {
                state.enrolled[value.key] = value
                changed = true
            }
        }
        if changed { try save(state) }
    }

    /// Commit migration once with its copied identities. Re-importing after
    /// source completion would otherwise resurrect already retired work.
    func importPresentationsOnce(_ values: [ReceiveWorkEnrollment]) throws {
        var state = try load()
        guard !state.importedPresentations else { return }
        for value in values where value.reference.isSupported &&
            !value.network.isEmpty && !value.identity.isEmpty {
            if state.enrolled[value.key] == nil { state.enrolled[value.key] = value }
        }
        state.importedPresentations = true
        try save(state)
    }

    func next(network: String, identity: String, purpose: String) throws -> [ReceiveWorkEnrollment] {
        var state = try load()
        let keys = state.enrolled.values.filter {
            $0.network == network && $0.identity == identity
        }.map(\.key).sorted()
        guard !keys.isEmpty else { return [] }
        let scope = [network, identity, purpose].joined(separator: "\0")
        let cursor = state.cursors[scope] ?? ""
        let start = keys.firstIndex(where: { $0 > cursor }) ?? 0
        let count = min(64, keys.count)
        let selected = (0..<count).map { keys[(start + $0) % keys.count] }
        state.cursors[scope] = selected.last
        // Do not claim rotation survived a restart unless it was committed.
        try save(state)
        return selected.compactMap { state.enrolled[$0] }
    }

    /// Canonical success is positive evidence. UI failure overlays, missing
    /// history rows and expired presentation consent are never cleanup proof.
    func reconcileCompleted(network: String, identity: String, entries: [Entry]) throws {
        let completed = Set(entries.filter { $0.kind == "receive" && $0.status == "complete" }.map(\.id))
        guard !completed.isEmpty else { return }
        var state = try load()
        let oldCount = state.enrolled.count
        state.enrolled = state.enrolled.filter { _, value in
            !(value.network == network && value.identity == identity &&
              value.canonicalID.map(completed.contains) == true)
        }
        if state.enrolled.count != oldCount { try save(state) }
    }

    /// Only matching source/canonical completion retires a source. Unknown refs,
    /// omitted results, failures and UI FAILED preserve the obligation.
    func reconcileSources(network: String, identity: String, selected: [ReceiveWorkEnrollment],
                          receipts: [LightningReceipt]) throws {
        var state = try load()
        var changed = false
        for receipt in receipts where receipt.state == "complete" {
            guard !receipt.canonicalID.isEmpty,
                  let value = selected.first(where: { $0.reference == receipt.reference }),
                  value.network == network, value.identity == identity,
                  value.canonicalID == nil || value.canonicalID == receipt.canonicalID,
                  state.enrolled[value.key] == value else { continue }
            state.enrolled.removeValue(forKey: value.key)
            changed = true
        }
        if changed { try save(state) }
    }

    private func load() throws -> ReceiveWorkState {
        guard let data = try storage.read(account: account) else { return .init() }
        return try JSONDecoder().decode(ReceiveWorkState.self, from: data)
    }

    private func save(_ state: ReceiveWorkState) throws {
        try storage.save(JSONEncoder().encode(state), account: account)
    }
}
