import XCTest
import WalletKit
@testable import Wavelength

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

    func testRefreshReservationPreservesDisplayedWalletBalance() throws {
        let decoder = JSONDecoder()
        let available = try decoder.decode(Balance.self, from: Data(
            #"{"ConfirmedSat":490166,"PendingInSat":0,"PendingOutSat":0}"#.utf8))
        let refreshing = try decoder.decode(Balance.self, from: Data(
            #"{"ConfirmedSat":0,"PendingInSat":0,"PendingOutSat":490166}"#.utf8))
        XCTAssertEqual(available.totalSat, refreshing.totalSat)
        XCTAssertEqual(refreshing.totalSat, 490_166)
        XCTAssertEqual(refreshing.confirmedSat, 0, "Refresh inputs must not become spendable")
        XCTAssertEqual(refreshing.pendingSat, 490_166)
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
