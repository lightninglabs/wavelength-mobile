import XCTest
import WalletKit
@testable import Wavelength

final class ActivityHistoryTests: XCTestCase {
    func testHistoryCanGrowPastTheLegacySnapshotLimit() throws {
        var history = ActivityHistory()
        var request: ActivityHistory.Page = .first
        let formatter = ISO8601DateFormatter()
        let count = 1_001
        let pageSize = Int(ActivityHistory.pageSize)
        for start in stride(from: 0, to: count, by: pageSize) {
            let end = min(start + pageSize, count)
            let rows = (start..<end).map { index -> [String: Any] in
                var entry = row("entry-\(index)", second: 15)
                entry["CreatedAt"] = formatter.string(from: Date(timeIntervalSince1970: Double(count - index)))
                return entry
            }
            try history.append(page(rows, next: end < count ? "cursor-\(end)" : nil), requested: request)
            XCTAssertEqual(history.entries.count, end)
            request = history.next
        }
        XCTAssertEqual(history.entries.last?.id, "entry-1000")
        XCTAssertEqual(history.next, .end)
    }

    func testPagesAndLiveChangesKeepOrderAndIndependentBoundaries() throws {
        var history = ActivityHistory()
        let a = row("a", second: 15, status: "pending")
        let b = row("b", second: 15)
        try history.append(page([a, b], next: "page-2"), requested: .first)

        let c = row("c", second: 15)
        let complete = try decode(row("a", second: 15, status: "complete"))
        history.mergeChanges([try decode(row("new", second: 16)),
                              try decode(row("aa", second: 15)),
                              try decode(c), complete, complete])
        XCTAssertEqual(history.entries.map(\.id), ["new", "a", "aa", "b"])
        XCTAssertEqual(history.entries[1].status, "complete")
        XCTAssertEqual(history.next, .older("page-2"))

        try history.append(page([c, row("old", second: 14)]), requested: .older("page-2"))
        XCTAssertEqual(history.entries.map(\.id), ["new", "a", "aa", "b", "c", "old"])
        XCTAssertEqual(history.next, .end)
        history.mergeChanges([try decode(row("backdated", second: 13))])
        XCTAssertEqual(history.entries.last?.id, "backdated")
    }

    func testEmptyPageWithContinuationAndRetryKeepTheToken() throws {
        var history = ActivityHistory()
        try history.append(page([], next: "next"), requested: .first)
        XCTAssertThrowsError(try history.append(page([], next: "next"), requested: .older("next")))
        XCTAssertEqual(history.next, .older("next"))
        try history.append(page([row("older", second: 13)]), requested: .older("next"))
        XCTAssertEqual(history.entries.map(\.id), ["older"])
        XCTAssertEqual(history.next, .end)
    }

    func testTransientDepositUsesOneIdentityAndCanonicalRowWins() throws {
        var history = ActivityHistory()
        let payment = row("payment", second: 15)
        var deposit = row("deposit-address", second: 16, status: "pending")
        deposit["Kind"] = "deposit"
        deposit["Progress"] = progress(txid: "", height: 0)
        try history.append(page([deposit, payment]), requested: .first)
        let overlay = try decode(deposit)
        deposit["CreatedAt"] = "2026-11-18T00:00:17Z"
        history.updateOverlay([try decode(deposit)])
        XCTAssertEqual(history.entries.first?.createdAt, overlay.createdAt)

        deposit["Progress"] = progress(txid: "tx", height: 20)
        history.mergeChanges([try decode(deposit)])
        history.updateOverlay([overlay])
        XCTAssertEqual(history.entries.map(\.id), ["deposit-address", "payment"])
        XCTAssertEqual(history.entries.first?.progress?.txid, "tx")
    }

    private func row(_ id: String, second: Int, status: String = "complete") -> [String: Any] {
        ["ID": id, "Kind": "send", "Status": status, "AmountSat": 1, "FeeSat": 0,
         "Counterparty": "", "Note": "", "CreatedAt": "2026-11-18T00:00:\(second)Z"]
    }

    private func progress(txid: String, height: Int) -> [String: Any] {
        ["Phase": "waiting_for_confirmation", "PhaseLabel": "waiting_for_confirmation", "PaymentHash": "",
         "Txid": txid, "ConfirmationHeight": height, "VTXOOutpoint": "", "Preimage": ""]
    }

    private func decode(_ row: [String: Any]) throws -> Entry {
        try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: row))
    }

    private func page(_ rows: [[String: Any]], next: String? = nil) throws -> ActivityList {
        let value: [String: Any] = ["Entries": rows, "Total": rows.count,
                                    "HasMore": next != nil, "NextCursor": next ?? ""]
        return try JSONDecoder().decode(ActivityList.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
