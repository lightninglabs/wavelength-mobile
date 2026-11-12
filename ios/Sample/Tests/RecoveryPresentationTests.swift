import XCTest
import WalletKit

final class RecoveryPresentationTests: XCTestCase {
    func testRequestIsNotShownAsReceivedBeforeFundsArrive() throws {
        let request = try entry(kind: "receive", status: "pending", phase: "waiting_for_payment")
        XCTAssertEqual(request.displayStatus, "Waiting for payment")
        XCTAssertTrue(request.isAwaitingIncomingPayment)
        let detected = try entry(kind: "deposit", status: "pending", phase: "waiting_for_confirmation")
        XCTAssertEqual(detected.displayStatus, "Receiving")
        XCTAssertFalse(detected.isAwaitingIncomingPayment)
        XCTAssertEqual(try entry(kind: "deposit", status: "complete", phase: "confirmed").displayStatus, "Received")
    }

    func testCreditTopupAndRefundRemainDistinctFromMerchantPayment() throws {
        let topup = try entry(kind: "send", status: "complete", phase: "confirmed", label: "credit_topup")
        XCTAssertEqual(topup.activityTitle, "Credit top-up")
        let refund = try entry(kind: "send", status: "failed", phase: "refunded", failure: "refunded")
        XCTAssertEqual(refund.displayStatus, "Refunded")
        XCTAssertEqual(try entry(kind: "send", status: "pending", phase: "refunding").displayStatus, "Refunding")
    }

    func testUnknownRefreshFeeIsNotDecodedAsZero() throws {
        let missing = try JSONDecoder().decode(RefreshResult.self, from: Data(#"{"QueuedOutpoints":["a:0"],"DryRun":true,"FeeEstimate":{"TotalFeeSat":null,"FreeRefreshEligible":false,"EstimateError":"unavailable"}}"#.utf8))
        XCTAssertNil(missing.feeEstimate?.totalFeeSat)
        let free = try JSONDecoder().decode(RefreshResult.self, from: Data(#"{"QueuedOutpoints":["a:0"],"DryRun":true,"FeeEstimate":{"TotalFeeSat":0,"FreeRefreshEligible":true,"EstimateError":""}}"#.utf8))
        XCTAssertEqual(free.feeEstimate?.totalFeeSat, 0)
    }

    private func entry(kind: String, status: String, phase: String,
                       label: String = "", failure: String = "") throws -> Entry {
        let json: [String: Any] = ["ID": "test", "Kind": kind, "Status": status,
            "AmountSat": 1000, "FeeSat": 0, "Counterparty": "", "Note": "",
            "FailureCode": failure, "Progress": ["Phase": phase, "PhaseLabel": label,
                "PaymentHash": "", "Txid": "", "ConfirmationHeight": 0, "VTXOOutpoint": "", "Preimage": ""]]
        return try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
