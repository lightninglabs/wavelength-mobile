import XCTest
import WalletKit

final class WalletModelDecodingTests: XCTestCase {
    func testDecodesDetailedActivityEntry() throws {
        let json = #"""
        {
          "ID": "activity-1",
          "Kind": "receive",
          "Status": "complete",
          "AmountSat": 21000,
          "FeeSat": 12,
          "Counterparty": "peer",
          "CreatedAt": "2026-08-11T10:00:00Z",
          "UpdatedAt": "2026-08-11T10:01:00Z",
          "Note": "coffee",
          "FailureReason": "",
          "FailureCode": "",
          "Cursor": 42,
          "Progress": {
            "Phase": "confirmed",
            "PhaseLabel": "confirmed",
            "PaymentHash": "hash",
            "Txid": "txid",
            "ConfirmationHeight": 123,
            "VTXOOutpoint": "outpoint:0",
            "Preimage": "preimage"
          },
          "Request": {
            "Type": "lightning",
            "LightningInvoice": "lnbc1example",
            "PaymentHash": "hash",
            "OnchainAddress": "",
            "ArkAddress": ""
          }
        }
        """#.data(using: .utf8)!

        let entry = try JSONDecoder().decode(Entry.self, from: json)
        XCTAssertEqual(entry.id, "activity-1")
        XCTAssertEqual(entry.amountSat, 21_000)
        XCTAssertEqual(entry.progress?.phase, "confirmed")
        XCTAssertEqual(entry.progress?.confirmationHeight, 123)
        XCTAssertEqual(entry.request?.lightningInvoice, "lnbc1example")
        XCTAssertEqual(entry.cursor, 42)
    }

    func testOlderActivityPayloadStillDecodes() throws {
        let json = #"""
        {
          "ID": "legacy",
          "Kind": "deposit",
          "Status": "pending",
          "AmountSat": 1000,
          "FeeSat": 0,
          "Counterparty": "",
          "Note": ""
        }
        """#.data(using: .utf8)!

        let entry = try JSONDecoder().decode(Entry.self, from: json)
        XCTAssertEqual(entry.id, "legacy")
        XCTAssertNil(entry.progress)
        XCTAssertNil(entry.request)
        XCTAssertNil(entry.createdAt)
    }

    func testOlderBalancePayloadStillDecodes() throws {
        let json = #"""
        {"ConfirmedSat": 5000, "PendingInSat": 20, "PendingOutSat": 10}
        """#.data(using: .utf8)!

        let balance = try JSONDecoder().decode(Balance.self, from: json)
        XCTAssertEqual(balance.confirmedSat, 5_000)
        XCTAssertNil(balance.creditAvailableSat)
    }
}
