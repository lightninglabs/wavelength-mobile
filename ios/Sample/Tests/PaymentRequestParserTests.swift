import XCTest
import WalletKit

final class PaymentRequestParserTests: XCTestCase {
    func testRawInvoiceIsUnchangedApartFromWhitespace() {
        XCTAssertEqual(
            PaymentRequestParser.normalizedDestination(from: "  lntbs1invoice\n"),
            "lntbs1invoice"
        )
    }

    func testLightningURIIsUnwrappedCaseInsensitively() {
        XCTAssertEqual(
            PaymentRequestParser.normalizedDestination(from: "LIGHTNING://LNTBS1INVOICE"),
            "LNTBS1INVOICE"
        )
    }

    func testBIP21PrefersEmbeddedLightningInvoice() {
        let request = "bitcoin:tb1ptest?amount=0.001&lightning=LIGHTNING%3Alntbs1invoice"
        XCTAssertEqual(
            PaymentRequestParser.normalizedDestination(from: request),
            "lntbs1invoice"
        )
    }

    func testBIP21WithoutLightningReturnsAddress() {
        XCTAssertEqual(
            PaymentRequestParser.normalizedDestination(
                from: "bitcoin:tb1ptest?amount=0.001&label=Wavelength"
            ),
            "tb1ptest"
        )
    }
}
