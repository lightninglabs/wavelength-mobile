import XCTest
@testable import WalletKit

final class SendAuthorizationTests: XCTestCase {
    func testCreditDefaultsAndIndependentOptOutsReachTheWire() throws {
        var request = PrepareSendReq(
            invoice: "lntb1example", onchainAddress: nil, amountSat: 0,
            note: "", maxFeeSat: 100, sweepAll: false
        )
        let defaults = try object(request)
        XCTAssertEqual(defaults["MaxCreditSat"] as? Int, 10_000)
        XCTAssertEqual(defaults["MaxCreditTopupSat"] as? Int, 10_000)

        // Permission to spend existing credit must not authorize new funding.
        request.maxCreditSat = 2_000
        request.maxCreditTopupSat = 0
        let creditOnly = try object(request)
        XCTAssertEqual(creditOnly["MaxCreditSat"] as? Int, 2_000)
        XCTAssertEqual(creditOnly["MaxCreditTopupSat"] as? Int, 0)

        request.maxCreditTopupSat = 500
        let topup = try object(request)
        XCTAssertEqual(topup["MaxCreditSat"] as? Int, 2_000)
        XCTAssertEqual(topup["MaxCreditTopupSat"] as? Int, 500)
        XCTAssertEqual(topup["MaxFeeSat"] as? Int, 100)

        request.maxCreditSat = 0
        request.maxCreditTopupSat = 0
        let disabled = try object(request)
        XCTAssertEqual(disabled["MaxCreditSat"] as? Int, 0)
        XCTAssertEqual(disabled["MaxCreditTopupSat"] as? Int, 0)
    }

    private func object(_ request: PrepareSendReq) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
