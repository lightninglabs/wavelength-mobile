import XCTest
@testable import WalletKit

final class WalletErrorTests: XCTestCase {
    func testRecognizesUncertainReceiveOutcome() {
        let error = WalletError(
            message: "receive outcome uncertain; reconcile Activity before retrying: context canceled"
        )

        XCTAssertTrue(error.isReceiveOutcomeUncertain)
    }

    func testDoesNotTreatGenericCancellationAsUncertainReceive() {
        let error = WalletError(message: "context canceled")

        XCTAssertFalse(error.isReceiveOutcomeUncertain)
    }

    func testRecognizesLegacyReceiveDeadline() {
        let error = WalletError(message: "context deadline exceeded")

        XCTAssertTrue(error.isDeadlineExceeded)
        XCTAssertFalse(error.isReceiveOutcomeUncertain)
    }
}
