import XCTest
import WalletKit

final class InvoiceDecodeTests: XCTestCase {
    private let amountless = "lnbcrt1pj48ugqpp59gqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqdq6gdhkven9v5s8w6t5dqsyzmr90qxq8zals8sqp3rd80lel9jpeccahy93q8p0mzx6lqj4zq2z0qxuf0sfpn5pdn5hh8queetm9kmd2e205m8cvtxvc0hj7l6yep5ckfyg9xs753p77wcp25m2jx"
    private let fixed = "lnbcrt250u1pj48ugqpp59gqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqdq6gdhkven9v5s8w6t5dqsyzmr90qxq8zals8sqtvg4lu5xz7cy89e2mnxuazfjglremld0nhd87udtf03pxme95pt4fstpduaz2u4g5dknwnghyw3al2vll3s5swgrvd4ewg6ghvervkcqkprr23"
    private let expired = "lnbcrt1pj48ugqpp59gqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqdq6gdhkven9v5s8w6t5dqsyzmr90qxqrrss5y4h4y723pt8rru8c2epcy6j5q64mupt3kap48u2w0yn4h8zcw3jefxar5wesswsfqwd32zn9ajyhsgna8dvcee3ttq9v4u43wxe8agq09rs0g"

    func testNativeDecoderDistinguishesMissingAndSignedAmounts() async throws {
        let client = WalletClient()
        let open = try await client.decodeInvoice(amountless, network: .regtest)
        XCTAssertNil(open.amountSat)
        XCTAssertEqual(open.description, "Coffee with Alex")
        let signed = try await client.decodeInvoice(fixed, network: .regtest)
        XCTAssertEqual(signed.amountSat, 25_000)
        let upper = try await client.decodeInvoice(amountless.uppercased(), network: .regtest)
        XCTAssertNil(upper.amountSat)
    }

    func testInvalidExpiredAndWrongNetworkInvoicesNeverBecomeAmountless() async {
        let client = WalletClient()
        for (invoice, network, reason) in [("lnbcrt1invalid", WalletNetwork.regtest, "invalid invoice"),
                                           (expired, .regtest, "expired"),
                                           (amountless, .mainnet, "invalid invoice")] {
            do {
                _ = try await client.decodeInvoice(invoice, network: network)
                XCTFail("Invalid invoice was accepted")
            } catch {
                XCTAssertTrue(String(describing: error).lowercased().contains(reason),
                              "Expected \(reason), received \(error)")
            }
        }
    }
}
