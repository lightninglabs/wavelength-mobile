import XCTest
@testable import Wavelength

final class PaymentFailureTests: XCTestCase {
    func testDustChangeExplainsTheActionAndKeepsOriginalEvidence() {
        let raw = "fund vHTLC: send oor transfer: rpc error: code = OutOfRange desc = VTXO selection failed: select and reserve: change below minimum vtxo amount: change 94 is below minimum change amount 1000"

        XCTAssertEqual(PaymentFailure.message(raw),
                       "This amount would leave too little change. Request a different amount or add funds.")
        XCTAssertEqual(PaymentFailure.technicalDetails(raw), raw)
    }

    func testUnknownTransportFailureDoesNotRecommendBlindRetry() {
        for code in ["Unknown", "Internal", "DeadlineExceeded", "Canceled", "Unavailable"] {
            let raw = "send: rpc error: code = \(code) desc = backend request failed"
            let message = PaymentFailure.message(raw)

            XCTAssertFalse(message.contains("rpc error"), code)
            XCTAssertTrue(message.contains("Activity before trying again"), code)
            XCTAssertFalse(message.contains("funds were not sent"), code)
            XCTAssertEqual(PaymentFailure.technicalDetails(raw), raw)
        }
    }

    func testInsufficientBalanceIncludesFees() {
        let raw = "rpc error: code = ResourceExhausted desc = insufficient spendable funds"
        XCTAssertEqual(PaymentFailure.message(raw),
                       "There isn’t enough available balance to cover this payment and its fees.")
    }

    func testValidationRejectionsKeepUsefulGuidanceWithoutRpcJargon() {
        for code in ["InvalidArgument", "FailedPrecondition", "OutOfRange"] {
            let raw = "rpc error: code = \(code) desc = amount outside allowed limits"
            XCTAssertEqual(PaymentFailure.message(raw),
                           "The request couldn’t be processed. Review the invoice, amount and fees.")
            XCTAssertEqual(PaymentFailure.technicalDetails(raw), raw)
        }
        let paid = "rpc error: code = FailedPrecondition desc = invoice already paid"
        XCTAssertEqual(PaymentFailure.message(paid),
                       "This invoice has already been paid. Ask the recipient for a new invoice.")
        let expired = "rpc error: code = InvalidArgument desc = invoice has expired"
        XCTAssertEqual(PaymentFailure.message(expired),
                       "This invoice has expired. Ask the recipient for a new invoice.")
    }

    func testCuratedMessagesAndInvoiceCompatibilityStayIntact() {
        for raw in ["Check Activity before sending again.", "This invoice has expired.",
                    SendAmount.prepareError("rpc error: code = InvalidArgument desc = invoice amount is required",
                                            amountlessInvoice: true)] {
            XCTAssertEqual(PaymentFailure.message(raw), raw)
            XCTAssertNil(PaymentFailure.technicalDetails(raw))
        }
    }
}
