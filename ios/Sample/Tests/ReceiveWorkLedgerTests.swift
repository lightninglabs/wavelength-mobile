import Foundation
import XCTest
import WalletKit
@testable import Wavelength

private final class WorkMemoryCredentials: NotificationCredentialStorage, @unchecked Sendable {
    var values: [String: Data] = [:]
    var rejectWrites = false
    func read(account: String) throws -> Data? { values[account] }
    func save(_ data: Data, account: String) throws {
        if rejectWrites { throw NotificationRelayError.unavailableCredentials }
        values[account] = data
    }
}

@MainActor
final class ReceiveWorkLedgerTests: XCTestCase {
    private func enrollment(_ id: Int, network: String = "signet", identity: String = "wallet") -> ReceiveWorkEnrollment {
        .init(network: network, identity: identity,
              reference: .init(source: "lightning_swap", id: String(format: "%03d", id)),
              canonicalID: "entry-\(id)")
    }

    private func entry(_ id: Int, status: String) throws -> Entry {
        try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: [
            "ID": "entry-\(id)", "Kind": "receive", "Status": status,
            "AmountSat": 123, "FeeSat": 0, "Counterparty": "", "Note": ""
        ]))
    }

    private func receipt(_ id: Int, state: String, canonical: String? = nil) throws -> LightningReceipt {
        try JSONDecoder().decode(LightningReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "reference": ["source": "lightning_swap", "id": String(format: "%03d", id)],
            "canonical_id": canonical ?? "entry-\(id)", "state": state,
            "amount_sat": 123, "created_at_unix": 1
        ]))
    }

    func testMoreThan64SurviveRestartAndRotateWithoutCrossWalletWork() throws {
        let storage = WorkMemoryCredentials()
        let ledger = ReceiveWorkLedger(storage: storage)
        try ledger.enroll((0..<130).map { enrollment($0) } + [
            enrollment(200, network: "mainnet"), enrollment(201, identity: "other")
        ])
        var visited: Set<String> = []
        for _ in 0..<3 {
            let restored = ReceiveWorkLedger(storage: storage)
            let next = try restored.next(network: "signet", identity: "wallet", purpose: "background")
            XCTAssertEqual(next.count, 64)
            XCTAssertTrue(next.allSatisfy { $0.network == "signet" && $0.identity == "wallet" })
            visited.formUnion(next.map(\.reference.id))
        }
        XCTAssertEqual(visited.count, 130, "Per-call limit must not evict or starve admitted work")
        XCTAssertEqual(try ledger.next(network: "mainnet", identity: "wallet", purpose: "background").count, 1)
        let encoded = String(decoding: try XCTUnwrap(storage.values["notification-receive-work.v1"]), as: UTF8.self)
        XCTAssertFalse(encoded.contains("amount"))
        XCTAssertFalse(encoded.contains("invoice"))
    }

    func testMissingFailedAndUnknownSourcesAreRetainedUntilPositiveCompletion() throws {
        let storage = WorkMemoryCredentials()
        let ledger = ReceiveWorkLedger(storage: storage)
        let enrolled = (0..<4).map { enrollment($0) }
        try ledger.enroll(enrolled)
        try ledger.reconcileCompleted(network: "signet", identity: "wallet", entries: [try entry(0, status: "failed")])
        try ledger.reconcileSources(network: "signet", identity: "wallet", selected: enrolled, receipts: [
            try receipt(0, state: "failed"), try receipt(1, state: "pending"),
            try receipt(2, state: "complete", canonical: "different-entry"), try receipt(900, state: "complete")
        ])
        XCTAssertEqual(try ledger.next(network: "signet", identity: "wallet", purpose: "background").count, 4)
        try ledger.reconcileCompleted(network: "mainnet", identity: "wallet", entries: [try entry(0, status: "complete")])
        try ledger.reconcileSources(network: "signet", identity: "other", selected: enrolled,
                                    receipts: [try receipt(0, state: "complete")])
        XCTAssertEqual(try ledger.next(network: "signet", identity: "wallet", purpose: "background").count, 4)
        try ledger.reconcileCompleted(network: "signet", identity: "wallet", entries: [try entry(0, status: "complete")])
        try ledger.reconcileSources(network: "signet", identity: "wallet", selected: enrolled,
                                    receipts: [try receipt(1, state: "complete")])
        XCTAssertEqual(Set(try ledger.next(network: "signet", identity: "wallet", purpose: "background").map(\.reference.id)), ["002", "003"])
    }

    func testMigrationAndWriteFailureCannotLoseOrResurrectWork() throws {
        let storage = WorkMemoryCredentials()
        let ledger = ReceiveWorkLedger(storage: storage)
        storage.rejectWrites = true
        XCTAssertThrowsError(try ledger.importPresentationsOnce([enrollment(0)]))
        storage.rejectWrites = false
        try ledger.importPresentationsOnce([enrollment(0)])
        try ledger.reconcileCompleted(network: "signet", identity: "wallet", entries: [try entry(0, status: "complete")])
        try ReceiveWorkLedger(storage: storage).importPresentationsOnce([enrollment(0)])
        XCTAssertTrue(try ledger.next(network: "signet", identity: "wallet", purpose: "background").isEmpty)
        try ledger.enroll([enrollment(1)])
        storage.rejectWrites = true
        XCTAssertThrowsError(try ledger.enroll([enrollment(2)]))
        XCTAssertThrowsError(try ledger.next(network: "signet", identity: "wallet", purpose: "background"))
        storage.rejectWrites = false
        try ledger.enroll([enrollment(2)])
        XCTAssertEqual(try ledger.next(network: "signet", identity: "wallet", purpose: "background").count, 2)
    }

    func testBannerConsentIsIndependentAndFailedEnrollmentIsRetried() throws {
        let suite = "receive-work-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = WorkMemoryCredentials()
        let ledger = ReceiveWorkLedger(storage: storage)
        let receipts = ReceiptNotificationLedger(storage: storage)
        let notifications = WalletNotifications(defaults: defaults, receiptLedger: receipts,
            receiveWorkLedger: ledger, configuration: { _ in nil },
            authorize: { XCTFail("Local work enrollment must not request banner consent"); return false }, registerDevice: {})
        let value = ReceiveResult(invoice: "not-stored", entry: try entry(0, status: "pending"),
                                  receiptReference: enrollment(0).reference)
        storage.rejectWrites = true
        notifications.enrollReceiveWork(value, network: "signet", identity: "wallet")
        XCTAssertNotNil(notifications.workRecoveryNotice)
        storage.rejectWrites = false
        notifications.enrollReceiveWork(ReceiveResult(invoice: "not-stored", entry: try entry(1, status: "pending"),
            receiptReference: enrollment(1).reference), network: "signet", identity: "wallet")
        XCTAssertNil(notifications.workRecoveryNotice)
        XCTAssertEqual(try ledger.next(network: "signet", identity: "wallet", purpose: "background").count, 2)
        XCTAssertNil(try receipts.consent(network: "signet"), "Work must not promote amount consent")
    }
}
