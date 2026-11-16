import XCTest
@testable import Wavelength

final class SendAmountTests: XCTestCase {
    func testWholeSatoshiAmounts() {
        XCTAssertEqual(SendAmount.satoshis("1"), 1)
        XCTAssertEqual(SendAmount.satoshis("25000"), 25_000)
        XCTAssertEqual(SendAmount.satoshis("2100000000000000"), 2_100_000_000_000_000)
    }

    func testInvalidOrOverflowingAmountsNeverEnableReview() {
        for input in ["", "0", "-1", "+1", "1.5", "1,000", " 10", "١٠", "2100000000000001", "9223372036854775808"] {
            XCTAssertNil(SendAmount.satoshis(input), input)
        }
    }

    func testLegacyServiceRejectionExplainsAmountlessCompatibility() {
        let rejection = "rpc error: code = InvalidArgument desc = invoice amount is required"
        XCTAssertTrue(SendAmount.prepareError(rejection, amountlessInvoice: true)
            .contains("Ask the recipient for an invoice with an amount."))
        XCTAssertEqual(SendAmount.prepareError(rejection, amountlessInvoice: false), rejection)
        XCTAssertEqual(SendAmount.prepareError("Connection unavailable", amountlessInvoice: true),
                       "Connection unavailable")
    }
}
