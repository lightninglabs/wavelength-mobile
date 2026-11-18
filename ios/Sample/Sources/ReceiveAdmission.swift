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

/// ReceiveAdmission creates one Lightning receive under a request ID made
/// before the call. When the reply is lost, the same ID reads back exactly
/// what the wallet admitted, including its receipt reference. It never
/// creates a second receive.
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
}
