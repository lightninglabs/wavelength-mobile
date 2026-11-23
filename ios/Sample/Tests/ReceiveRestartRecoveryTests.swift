import Foundation
import XCTest
@testable import WalletKit
@testable import Wavelength

private final class RestartMemoryCredentials: NotificationCredentialStorage, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { values[account] }
    func save(_ data: Data, account: String) throws { values[account] = data }
}

private struct AppTerminated: Error {}

@MainActor
final class ReceiveRestartRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        suite = "receive-restart-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private var journal: PendingReceiveJournal {
        PendingReceiveJournal(defaults: defaults, key: "signet.pendingReceive")
    }

    private let pending = PendingReceive(requestID: "req-1", amountSat: 1_000, memo: "coffee",
                                         network: "signet", identity: "wallet")

    private func admitted() throws -> ReceiveResult {
        let entry = try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: [
            "ID": "entry-1", "Kind": "receive", "Status": "pending",
            "AmountSat": 1_000, "FeeSat": 0, "Counterparty": "", "Note": "coffee"
        ]))
        return ReceiveResult(invoice: "lnbc1", entry: entry,
                             receiptReference: .init(source: "lightning_swap", id: "entry-1"))
    }

    func testReceiveAdmittedBeforeTerminationIsRecoveredOnRelaunch() async throws {
        // First run: the daemon admits the receive, then the app is killed
        // before the reply is enrolled. AppTerminated stands in for the kill:
        // nothing after the create call runs.
        var created: [String] = []
        do {
            _ = try await ReceiveAdmission.create(
                pending, journal: journal,
                create: { id in
                    XCTAssertEqual(self.journal.load(), self.pending, "Record must be durable before create")
                    created.append(id)
                    throw AppTerminated()
                },
                lookup: { _ in XCTFail("lookup"); return nil },
                enroll: { _ in XCTFail("enroll") }
            )
            XCTFail("expected termination")
        } catch is AppTerminated {}
        XCTAssertEqual(created, ["req-1"])

        // Relaunch: a fresh journal reads the same preferences.
        let relaunched = PendingReceiveJournal(defaults: defaults, key: "signet.pendingReceive")
        XCTAssertEqual(relaunched.load(), pending)

        let storage = RestartMemoryCredentials()
        let ledger = ReceiveWorkLedger(storage: storage)
        let notifications = WalletNotifications(
            defaults: defaults, receiptLedger: ReceiptNotificationLedger(storage: storage),
            receiveWorkLedger: ledger, configuration: { _ in nil },
            authorize: { false }, registerDevice: {}
        )
        let original = try admitted()
        var looked: [String] = []
        await ReceiveAdmission.recover(
            journal: relaunched,
            lookup: { id in looked.append(id); return original },
            enroll: { record, result in
                notifications.enrollReceiveWork(result, network: record.network, identity: record.identity!)
            }
        )

        XCTAssertEqual(looked, ["req-1"])
        XCTAssertEqual(created, ["req-1"], "Recovery must never create another receive")
        XCTAssertNil(relaunched.load())
        let work = try ledger.next(network: "signet", identity: "wallet", purpose: "background")
        XCTAssertEqual(work.map(\.reference.id), ["entry-1"])
    }

    func testRecoveryClearsNotFoundAndKeepsLookupError() async throws {
        try journal.save(pending)
        await ReceiveAdmission.recover(
            journal: journal,
            lookup: { _ in throw WalletError(message: "rpc unavailable") },
            enroll: { _, _ in XCTFail("enroll") }
        )
        XCTAssertEqual(journal.load(), pending, "A failed lookup keeps the record for the next launch")

        await ReceiveAdmission.recover(
            journal: journal,
            lookup: { _ in nil },
            enroll: { _, _ in XCTFail("enroll") }
        )
        XCTAssertNil(journal.load())
    }

    func testCompletedReceiveClearsRecordAfterEnroll() async throws {
        let original = try admitted()
        var enrolled = false
        _ = try await ReceiveAdmission.create(
            pending, journal: journal,
            create: { _ in original },
            lookup: { _ in nil },
            enroll: { _ in
                XCTAssertNotNil(self.journal.load(), "Record must outlive enrollment")
                enrolled = true
            }
        )
        XCTAssertTrue(enrolled)
        XCTAssertNil(journal.load())
    }
}
