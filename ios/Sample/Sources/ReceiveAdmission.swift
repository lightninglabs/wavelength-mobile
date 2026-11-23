import Foundation
import WalletKit

/// The receive call ended without a result, and the follow-up lookup also
/// failed, so whether an invoice exists is still unknown.
struct ReceiveCreationUncertainError: LocalizedError {
    var errorDescription: String? {
        "The receive request ended before Wavelength could confirm the result. Check Activity before trying again."
    }
}

/// The receive call ended without a result, and the wallet has no pending or
/// completed receive under its request ID. Either none was created, or a
/// sub-floor receive created under it has already failed. A new attempt uses a
/// fresh request ID.
struct ReceiveNotCreatedError: LocalizedError {
    var errorDescription: String? {
        "No active receive was found. Try again."
    }
}

/// The one Lightning receive whose create may have reached the wallet but
/// whose result was not yet enrolled. It is saved before the create call, so
/// a receive admitted just before iOS kills the app can be read back by its
/// request ID after relaunch instead of being lost or created again.
struct PendingReceive: Codable, Equatable {
    let requestID: String
    let amountSat: Int64
    let memo: String
    let network: String
    let identity: String?
}

/// PendingReceiveJournal keeps the single pending receive in the wallet's
/// per-network preferences.
struct PendingReceiveJournal {
    let defaults: UserDefaults
    let key: String

    func load() -> PendingReceive? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PendingReceive.self, from: $0) }
    }

    func save(_ pending: PendingReceive) throws {
        defaults.set(try JSONEncoder().encode(pending), forKey: key)
    }

    /// Clears the record only if it still names this request, so a newer
    /// receive saved meanwhile is kept.
    func clear(_ requestID: String) {
        guard load()?.requestID == requestID else { return }
        defaults.removeObject(forKey: key)
    }
}

/// ReceiveAdmission creates one Lightning receive under a request ID made
/// before the call. When the reply is lost, the same ID reads back exactly
/// what the wallet admitted, including its receipt reference. It never
/// creates a second receive.
@MainActor
enum ReceiveAdmission {
    static func create(
        requestID: String,
        create: (String) async throws -> ReceiveResult,
        lookup: (String) async throws -> ReceiveResult?
    ) async throws -> ReceiveResult {
        do {
            return try await create(requestID)
        } catch let error as WalletError
            where error.isReceiveOutcomeUncertain || error.isDeadlineExceeded {
            let found: ReceiveResult?
            do {
                found = try await lookup(requestID)
            } catch {
                throw ReceiveCreationUncertainError()
            }
            guard let found else { throw ReceiveNotCreatedError() }
            return found
        }
    }

    /// Creates the receive with its record saved first. The record is
    /// cleared once the result is enrolled, or once the wallet confirms no
    /// receive exists. Any other failure leaves it for launch recovery.
    static func create(
        _ pending: PendingReceive,
        journal: PendingReceiveJournal,
        create: (String) async throws -> ReceiveResult,
        lookup: (String) async throws -> ReceiveResult?,
        enroll: (ReceiveResult) -> Void
    ) async throws -> ReceiveResult {
        try journal.save(pending)
        let result: ReceiveResult
        do {
            result = try await Self.create(requestID: pending.requestID, create: create, lookup: lookup)
        } catch let error as ReceiveNotCreatedError {
            journal.clear(pending.requestID)
            throw error
        }
        enroll(result)
        journal.clear(pending.requestID)
        return result
    }

    /// Reads back a receive left pending by an earlier run. Found: enroll and
    /// clear. Not found: clear. Lookup error: keep it for the next launch.
    /// This never creates a receive.
    static func recover(
        journal: PendingReceiveJournal,
        lookup: (String) async throws -> ReceiveResult?,
        enroll: (PendingReceive, ReceiveResult) -> Void
    ) async {
        guard let pending = journal.load() else { return }
        let found: ReceiveResult?
        do {
            found = try await lookup(pending.requestID)
        } catch {
            return
        }
        if let found { enroll(pending, found) }
        journal.clear(pending.requestID)
    }
}
