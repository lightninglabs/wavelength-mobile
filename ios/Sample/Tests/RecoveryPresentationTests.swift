import XCTest
import WalletKit

final class RecoveryPresentationTests: XCTestCase {
    func testRequestIsNotShownAsReceivedBeforeFundsArrive() throws {
        let detected = try entry(kind: "deposit", status: "pending", phase: "waiting_for_confirmation")
        XCTAssertEqual(detected.displayStatus, "Receiving")
        XCTAssertFalse(detected.isAwaitingIncomingPayment)
        XCTAssertTrue(detected.showsActivityProgress)
        XCTAssertEqual(try entry(kind: "deposit", status: "complete", phase: "confirmed").displayStatus, "Received")
    }

    func testLightningReceiveStatusFollowsObservedProgress() throws {
        let request = try entry(kind: "receive", status: "pending", phase: "waiting_for_payment")
        XCTAssertEqual(request.displayStatus, "Waiting for payment")
        XCTAssertTrue(request.isAwaitingIncomingPayment)
        XCTAssertFalse(request.showsActivityProgress)

        let accepted = try entry(kind: "receive", status: "pending", phase: "awaiting_funding")
        XCTAssertEqual(accepted.displayStatus, "Awaiting funding")
        XCTAssertFalse(accepted.isAwaitingIncomingPayment)
        XCTAssertFalse(accepted.showsActivityProgress)

        let funded = try entry(kind: "receive", status: "pending", phase: "settling", outpoint: "funded:0")
        XCTAssertEqual(funded.displayStatus, "Receiving")
        XCTAssertFalse(funded.isAwaitingIncomingPayment)
        XCTAssertTrue(funded.showsActivityProgress)

        let received = try entry(kind: "receive", status: "complete", phase: "confirmed")
        XCTAssertEqual(received.displayStatus, "Received")
        XCTAssertFalse(received.showsActivityProgress)

        let expired = try entry(kind: "receive", status: "failed", phase: "failed", failure: "expired")
        XCTAssertEqual(expired.displayStatus, "Expired")
        XCTAssertFalse(expired.isAwaitingIncomingPayment)
        XCTAssertFalse(expired.showsActivityProgress)
    }

    func testLegacyAndUnknownReceivePhasesStayStatic() throws {
        for phase in ["settling", "unspecified", "future_phase"] {
            let pending = try entry(kind: "receive", status: "pending", phase: phase)
            XCTAssertEqual(pending.displayStatus, "Checking status", phase)
            XCTAssertFalse(pending.isAwaitingIncomingPayment, phase)
            XCTAssertFalse(pending.showsActivityProgress, phase)
        }

        let replayed = try entry(kind: "receive", status: "pending", phase: "unspecified",
                                 label: "awaiting_funding")
        XCTAssertEqual(replayed.displayStatus, "Awaiting funding")
        XCTAssertFalse(replayed.showsActivityProgress)
    }

    func testReceiveWithoutLightningMetadataKeepsLedgerPresentation() throws {
        let ledgerReceive = try entry(kind: "receive", status: "pending", phase: "payment_detected",
                                      paymentHash: "")
        XCTAssertEqual(ledgerReceive.displayStatus, "Receiving")
        XCTAssertFalse(ledgerReceive.isAwaitingIncomingPayment)
        XCTAssertTrue(ledgerReceive.showsActivityProgress)
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
                       label: String = "", failure: String = "", outpoint: String = "",
                       paymentHash: String? = nil) throws -> Entry {
        let progress: [String: Any] = [
            "Phase": phase, "PhaseLabel": label,
            "PaymentHash": paymentHash ?? (kind == "receive" ? "payment-hash" : ""),
            "Txid": "", "ConfirmationHeight": 0, "VTXOOutpoint": outpoint, "Preimage": ""
        ]
        let json: [String: Any] = ["ID": "test", "Kind": kind, "Status": status,
            "AmountSat": 1000, "FeeSat": 0, "Counterparty": "", "Note": "",
            "FailureCode": failure, "Progress": progress]
        return try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
