import Foundation
import XCTest
@testable import WalletKit
@testable import Wavelength

private final class AdmissionMemoryCredentials: NotificationCredentialStorage, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { values[account] }
    func save(_ data: Data, account: String) throws { values[account] = data }
}

@MainActor
final class ReceiveAdmissionTests: XCTestCase {
    private let uncertain = WalletError(
        message: "receive outcome uncertain; reconcile activity before retrying: context deadline exceeded"
    )

    private func admitted() throws -> ReceiveResult {
        let entry = try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: [
            "ID": "entry-1", "Kind": "receive", "Status": "pending",
            "AmountSat": 1_000, "FeeSat": 0, "Counterparty": "", "Note": "coffee"
        ]))
        return ReceiveResult(invoice: "lnbc1", entry: entry,
                             receiptReference: .init(source: "lightning_swap", id: "entry-1"))
    }

    func testTimedOutReceiveRecoveredByLookupIsEnrolledForWork() async throws {
        let original = try admitted()
        var created: [String] = []
        var looked: [String] = []
        let result = try await ReceiveAdmission.create(
            requestID: "req-1",
            create: { id in created.append(id); throw self.uncertain },
            lookup: { id in looked.append(id); return original }
        )

        XCTAssertEqual(created, ["req-1"], "Recovery must not create a second receive")
        XCTAssertEqual(looked, ["req-1"])
        XCTAssertEqual(result.invoice, "lnbc1")
        XCTAssertEqual(result.receiptReference?.id, "entry-1")

        let suite = "receive-admission-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = AdmissionMemoryCredentials()
        let ledger = ReceiveWorkLedger(storage: storage)
        let notifications = WalletNotifications(
            defaults: defaults, receiptLedger: ReceiptNotificationLedger(storage: storage),
            receiveWorkLedger: ledger, configuration: { _ in nil },
            authorize: { false }, registerDevice: {}
        )
        notifications.enrollReceiveWork(result, network: "signet", identity: "wallet")

        let work = try ledger.next(network: "signet", identity: "wallet", purpose: "background")
        XCTAssertEqual(work.map(\.reference.id), ["entry-1"])
        XCTAssertEqual(work.map(\.canonicalID), ["entry-1"])
    }

    func testLookupOutcomesAfterUncertainReceive() async throws {
        do {
            _ = try await ReceiveAdmission.create(
                requestID: "req-2",
                create: { _ in throw self.uncertain },
                lookup: { _ in nil }
            )
            XCTFail("A missing receive must not look created")
        } catch {
            XCTAssertTrue(error is ReceiveNotCreatedError)
        }

        do {
            _ = try await ReceiveAdmission.create(
                requestID: "req-3",
                create: { _ in throw self.uncertain },
                lookup: { _ in throw WalletError(message: "rpc unavailable") }
            )
            XCTFail("A failed lookup must stay uncertain")
        } catch {
            XCTAssertTrue(error is ReceiveCreationUncertainError)
        }
    }

    func testBareDeadlineTriggersLookup() async throws {
        let original = try admitted()
        var looked = false
        let result = try await ReceiveAdmission.create(
            requestID: "req-5",
            create: { _ in throw WalletError(message: "context deadline exceeded") },
            lookup: { _ in looked = true; return original }
        )
        XCTAssertTrue(looked)
        XCTAssertEqual(result.receiptReference?.id, "entry-1")
    }

    func testSuccessNeverLooksUp() async throws {
        let original = try admitted()
        var looked = false
        let result = try await ReceiveAdmission.create(
            requestID: "req-6",
            create: { _ in original },
            lookup: { _ in looked = true; return nil }
        )
        XCTAssertFalse(looked)
        XCTAssertEqual(result.invoice, "lnbc1")
    }

    func testOtherFailuresPassThroughWithoutLookup() async throws {
        var looked = false
        do {
            _ = try await ReceiveAdmission.create(
                requestID: "req-4",
                create: { _ in throw WalletError(message: "amount exceeds the operator's maximum VTXO size") },
                lookup: { _ in looked = true; return nil }
            )
            XCTFail("expected the original error")
        } catch let error as WalletError {
            XCTAssertTrue(error.message.contains("maximum VTXO size"))
        }
        XCTAssertFalse(looked)
    }
}
