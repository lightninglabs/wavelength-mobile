import XCTest
import WalletKit
@testable import Wavelength

final class RecoveryPresentationTests: XCTestCase {
    func testExitFundingCoversBothOutputCountAndValueShortfall() throws {
        let entry = try exitPlanEntry(required: 3, usable: 1, shortfall: 25001)
        let funding = try XCTUnwrap(UnilateralExitFunding(entry))
        XCTAssertEqual(funding.paymentCount, 2)
        XCTAssertEqual(funding.satsPerPayment, 12501)
    }

    func testExitFundingWithMissingOutputsAndZeroValueShortfall() throws {
        let entry = try exitPlanEntry(required: 3, usable: 1, shortfall: 0,
                                      reason: "wallet_too_few_inputs")
        let funding = try XCTUnwrap(UnilateralExitFunding(entry))
        XCTAssertEqual(funding.paymentCount, 2)
        XCTAssertEqual(funding.satsPerPayment, 10000)
        XCTAssertNil(UnilateralExitFunding(try exitPlanEntry(required: 3, usable: 3, shortfall: 0,
                                                            reason: "wallet_too_few_inputs")))
    }

    func testExitFundingUsesOnePaymentForBalanceOnlyShortfall() throws {
        let entry = try exitPlanEntry(required: 2, usable: 2, shortfall: 4500)
        let funding = try XCTUnwrap(UnilateralExitFunding(entry))
        XCTAssertEqual(funding.paymentCount, 1)
        XCTAssertEqual(funding.satsPerPayment, 10000)
        XCTAssertNil(UnilateralExitFunding(try exitPlanEntry(required: 2, usable: 2, shortfall: 0, canStart: true)))
    }

    func testBlockedExitDoesNotOfferMisleadingDepositFromOlderSDK() throws {
        for reason in ["uneconomical", "sweep_below_dust"] {
            let entry = try exitPlanEntry(required: 2, usable: 0, shortfall: 24786, reason: reason)
            XCTAssertNil(UnilateralExitFunding(entry), reason)
        }
    }

    func testSelectionQuoteRequiresExactTargetsAndCustomTerms() throws {
        let preview = try exitPreview()
        let options = UnilateralExitOptions(sweepAddress: "TB1QEXAMPLE", feeRateSatPerVByte: 7)
        let quote = try UnilateralExitQuote(preview: preview, outpoints: ["a:0", "b:0"], options: options)
        XCTAssertEqual(quote.preview.estimatedNetworkFeeSat, 8400)
        XCTAssertEqual(quote.preview.walletFeeSat, 6700)
        XCTAssertTrue(quote.needsFunding)
        XCTAssertThrowsError(try UnilateralExitQuote(preview: preview, outpoints: ["b:0", "a:0"], options: options))
        for wrongOption in [UnilateralExitOptions(sweepAddress: "tb1qother", feeRateSatPerVByte: 7),
                            UnilateralExitOptions(sweepAddress: "tb1qexample", feeRateSatPerVByte: 8)] {
            XCTAssertThrowsError(try UnilateralExitQuote(preview: preview, outpoints: ["a:0", "b:0"],
                                                        options: wrongOption))
        }
    }

    func testSelectionQuoteRetainsRefusedTargetWithFundingEstimateForRemainingFunds() throws {
        let preview = try exitPreview(blocked: true)
        let options = UnilateralExitOptions(sweepAddress: "tb1qexample", feeRateSatPerVByte: 7)
        let quote = try UnilateralExitQuote(preview: preview, outpoints: ["a:0", "b:0"], options: options)
        XCTAssertEqual(quote.blocked.map(\.outpoint), ["a:0"])
        XCTAssertTrue(quote.economicBlock)
        XCTAssertFalse(quote.allUneconomical)
        XCTAssertEqual(quote.blockedMessage(try XCTUnwrap(quote.blocked.first)), "Fees would use up this amount")
    }

    private func exitPreview(blocked: Bool = false) throws -> UnilateralExitPreview {
        let targets = ["a:0", "b:0"].map { outpoint in
            let refused = blocked && outpoint == "a:0"
            return ["Outpoint": outpoint, "AmountSat": 50_000, "ExitStatus": "unspecified",
                    "RoundCommitment": "", "AdmissionError": refused ? "fee exceeds value" : "",
                    "InfeasibilityReason": refused ? "uneconomical" : "feasible"] as [String: Any]
        }
        let json: [String: Any] = [
            "SelectedAmountSat": 100_000, "FeeRateSatPerVByte": 7, "EstimatedTransactions": 9,
            "EstimatedNetworkFeeSat": 8400, "WalletFeeSat": 6700, "AdditionalFundingSat": 7500,
            "FundingAction": "deposit", "SweepAddress": "tb1qexample", "Entries": targets
        ]
        return try JSONDecoder().decode(UnilateralExitPreview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testCommittedExitDoesNotOfferFeeFunding() throws {
        let entry = try exitPlanEntry(required: 2, usable: 1, shortfall: 10000, roundCommitment: "active")
        XCTAssertNil(UnilateralExitFunding(entry))
    }

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

    private func exitPlanEntry(required: Int, usable: Int, shortfall: Int,
                               canStart: Bool = false, roundCommitment: String = "",
                               reason: String = "wallet_underfunded") throws -> ExitPlanEntry {
        let data: [String: Any] = ["Outpoint": "fund:0", "FundingAddress": "fixture",
            "RequiredConfirmations": 1, "RequiredFeeUTXOCount": required, "UsableFeeUTXOCount": usable,
            "RecommendedUTXOAmountSat": 10000, "FundingShortfallSat": shortfall, "CanStart": canStart,
            "InfeasibilityReason": reason, "ExitJobFound": false, "ExitStatus": "",
            "LastError": "", "RoundCommitment": roundCommitment, "Err": ""]
        return try JSONDecoder().decode(ExitPlanEntry.self, from: JSONSerialization.data(withJSONObject: data))
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
