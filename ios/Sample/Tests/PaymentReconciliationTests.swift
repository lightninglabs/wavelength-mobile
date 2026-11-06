import XCTest
import WalletKit
@testable import Wavelength

@MainActor
final class PaymentReconciliationTests: XCTestCase {
    func testOnlyNewPaymentEvidenceResolvesTheCurrentAttempt() throws {
        let pending = PendingDispatch(intentID: "intent", amountSat: 999, paymentHash: "hash",
            selectedOutpoints: ["input:0"], existingEntryIDs: ["old"],
            startedAt: Date(timeIntervalSince1970: 1000.75), destination: "destination")
        XCTAssertFalse(pending.matches(try entry(id: "old", created: 1002)))
        XCTAssertFalse(pending.matches(try entry(id: "late-old", created: 999)))
        XCTAssertFalse(pending.matches(try entry(id: "funding", created: 1002, label: "credit_topup")))
        XCTAssertTrue(pending.matches(try entry(id: "same-second", created: 1000)))
        XCTAssertTrue(pending.matches(try entry(id: "new", created: 1002)))
        let exit = PendingDispatch(intentID: "intent", amountSat: 999, paymentHash: "",
            selectedOutpoints: ["input:0"], existingEntryIDs: ["old"],
            startedAt: Date(timeIntervalSince1970: 1000.75), destination: "destination")
        XCTAssertFalse(exit.matches(try entry(id: "old", created: 1002, kind: "exit")))
        XCTAssertFalse(exit.matches(try entry(id: "late-old", created: 999, kind: "exit")))
        XCTAssertFalse(exit.matches(try entry(id: "other", created: 1002, kind: "exit", destination: "another destination")))
        XCTAssertTrue(exit.matches(try entry(id: "same-second", created: 1000, kind: "exit")))
        XCTAssertTrue(exit.matches(try entry(id: "new", created: 1002, kind: "exit")))
        XCTAssertFalse(PendingDispatch(intentID: "intent", amountSat: 999, paymentHash: "hash")
            .matches(try entry(id: "new", created: 1002)))
    }

    func testAcknowledgmentRetainsAnUnknownSendAcrossRelaunch() throws {
        try withFixture { defaults, root in
            var pending = PendingDispatch(intentID: "unknown", amountSat: 999, paymentHash: "hash",
                existingEntryIDs: [], startedAt: Date(), error: "Response lost", checks: 1)
            defaults.set(try JSONEncoder().encode(pending), forKey: "signet.pendingDispatch")
            let blocked = WalletStore(defaults: defaults, dataRoot: root)
            blocked.startSeparatePaymentAfterChecking()
            XCTAssertNotNil(blocked.pendingDispatch)
            pending.checks = 2
            defaults.set(try JSONEncoder().encode(pending), forKey: "signet.pendingDispatch")
            let checked = WalletStore(defaults: defaults, dataRoot: root)
            checked.startSeparatePaymentAfterChecking()
            XCTAssertNil(checked.pendingDispatch)
            let reopened = WalletStore(defaults: defaults, dataRoot: root)
            XCTAssertNil(reopened.pendingDispatch)
            XCTAssertEqual(reopened.unresolvedDispatches.count, 1)
            XCTAssertEqual(reopened.unresolvedDispatches.first?.intentID, "unknown")
            XCTAssertEqual(reopened.unresolvedDispatches.first?.error, "Response lost")
        }
    }

    func testAcknowledgmentRetainsAnUnknownSweepAcrossRelaunch() throws {
        try withFixture { defaults, root in
            var sweep = SweepOperation(destination: "destination", amountSat: 999, feeRate: 2,
                error: "Broadcast outcome unknown", startedAt: Date(), checks: 1)
            defaults.set(try JSONEncoder().encode(sweep), forKey: "signet.sweep")
            let blocked = WalletStore(defaults: defaults, dataRoot: root)
            blocked.startSeparateSweepAfterChecking()
            XCTAssertNotNil(blocked.sweepOperation)
            sweep.checks = 2
            defaults.set(try JSONEncoder().encode(sweep), forKey: "signet.sweep")
            let checked = WalletStore(defaults: defaults, dataRoot: root)
            checked.startSeparateSweepAfterChecking()
            XCTAssertNil(checked.sweepOperation)
            let reopened = WalletStore(defaults: defaults, dataRoot: root)
            XCTAssertNil(reopened.sweepOperation)
            XCTAssertEqual(reopened.unresolvedSweeps.count, 1)
            XCTAssertEqual(reopened.unresolvedSweeps.first?.destination, "destination")
            XCTAssertEqual(reopened.unresolvedSweeps.first?.error, "Broadcast outcome unknown")
        }
    }

    private func withFixture(_ body: (UserDefaults, URL) throws -> Void) throws {
        let suite = "payment-reconciliation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("signet", forKey: "selectedNetwork")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try body(defaults, FileManager.default.temporaryDirectory.appendingPathComponent(suite))
    }

    private func entry(id: String, created: TimeInterval, kind: String = "send",
                       label: String = "confirmed", destination: String = "destination") throws -> Entry {
        let object: [String: Any] = [
            "ID": id, "Kind": kind, "Status": "pending", "AmountSat": 999,
            "FeeSat": 0, "Counterparty": "", "Note": "",
            "CreatedAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: created)),
            "Progress": ["Phase": "pending", "PhaseLabel": label, "PaymentHash": "hash",
                "Txid": "", "ConfirmationHeight": 0, "VTXOOutpoint": "input:0", "Preimage": ""],
            "Request": ["Type": "onchain", "LightningInvoice": "", "PaymentHash": "hash",
                "OnchainAddress": destination, "ArkAddress": ""]
        ]
        return try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
