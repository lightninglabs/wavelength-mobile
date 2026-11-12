import XCTest
import WalletKit

final class ExitFeeTests: XCTestCase {
    func testNativeFeePayloadPreservesSelectedInputAndZero() throws {
        let paid = try estimate(fee: 12)
        XCTAssertEqual(paid.outpoint, "selected:1")
        XCTAssertEqual(paid.amountSat, 8_000)
        XCTAssertEqual(paid.estimatedFeeSat, 12)
        XCTAssertTrue(paid.canExit)

        let free = try estimate(fee: 0)
        XCTAssertEqual(free.estimatedFeeSat, 0)
        XCTAssertTrue(free.canExit)

        let missingFee = Data(#"{"Outpoint":"selected:1","AmountSat":8000,"BelowDustWarning":false}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ExitFeeEstimate.self, from: missingFee))
    }

    func testUneconomicOrDustQuoteCannotAuthorizeExit() throws {
        XCTAssertFalse(try estimate(fee: 8_000).canExit)
        XCTAssertFalse(try estimate(fee: 8_001).canExit)
        XCTAssertFalse(try estimate(fee: 12, belowDust: true).canExit)
    }

    func testUnstartedNativeRuntimeFailsInsteadOfReturningZeroFee() async throws {
        let client = WalletClient()
        do {
            _ = try await client.estimateExitFee(outpoint: "selected:1")
            XCTFail("An unavailable native runtime must not produce a free exit")
        } catch let error as WalletError {
            XCTAssertTrue(error.message.contains("not started"), error.message)
        }
    }

    private func estimate(fee: Int64, belowDust: Bool = false) throws -> ExitFeeEstimate {
        let payload: [String: Any] = [
            "Outpoint": "selected:1", "AmountSat": 8_000,
            "EstimatedFeeSat": fee, "BelowDustWarning": belowDust
        ]
        return try JSONDecoder().decode(ExitFeeEstimate.self,
            from: JSONSerialization.data(withJSONObject: payload))
    }
}
