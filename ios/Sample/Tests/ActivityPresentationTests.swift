import XCTest
import WalletKit

final class ActivityPresentationTests: XCTestCase {
    func testCreditFundingIsGroupedWithTheExactPayment() throws {
        let receive = try entry(id: "receive", kind: "receive", amount: 10000, hash: "incoming")
        let payment = try entry(id: "payment", amount: -999, hash: "paid")
        let funding = try entry(id: "funding", amount: -1000, label: "credit_topup", hash: "paid")
        let otherPayment = try entry(id: "other", amount: -999, hash: "different")
        let entries = [payment, funding, otherPayment, receive]

        XCTAssertEqual(WalletActivityPresentation.entries(entries).map(\.id),
                       ["payment", "other", "receive"])
        XCTAssertEqual(WalletActivityPresentation.creditTopups(for: payment, in: entries).map(\.id), ["funding"])
        XCTAssertTrue(WalletActivityPresentation.creditTopups(for: otherPayment, in: entries).isEmpty)
        XCTAssertEqual(payment.amountSat, -999)
        XCTAssertEqual(funding.amountSat, -1000)
    }

    func testUnknownTransfersOrphanFundingAndFailuresStayVisible() throws {
        let payment = try entry(id: "payment", amount: -999, hash: "paid")
        let rawLedger = try entry(id: "ledger-3", amount: -1000, hash: "")
        let orphan = try entry(id: "orphan", amount: -1000, label: "credit_topup", hash: "missing")
        let failed = try entry(id: "failed", status: "failed", amount: -1000, label: "credit_topup", hash: "paid")
        let uncorrelated = try entry(id: "uncorrelated", amount: -1000, label: "credit_topup", hash: "")
        let entries = [payment, rawLedger, orphan, failed, uncorrelated]
        XCTAssertEqual(WalletActivityPresentation.entries(entries).map(\.id), entries.map(\.id))
    }

    private func entry(id: String, kind: String = "send", status: String = "complete",
                       amount: Int64, label: String = "confirmed", hash: String) throws -> Entry {
        let object: [String: Any] = [
            "ID": id, "Kind": kind, "Status": status, "AmountSat": amount,
            "FeeSat": 0, "Counterparty": "", "Note": "", "Progress": [
                "Phase": "confirmed", "PhaseLabel": label, "PaymentHash": hash,
                "Txid": "", "ConfirmationHeight": 0, "VTXOOutpoint": "", "Preimage": ""
            ]
        ]
        return try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
