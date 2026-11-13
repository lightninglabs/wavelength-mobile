import XCTest
import SwiftUI
import WalletKit
@testable import Wavelength

@MainActor
final class DiagnosticsTests: XCTestCase {
    func testCaptureLevelPreservesLegacyChoiceAndDefaultsToInfo() throws {
        let name = "capture-level-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(DiagnosticCaptureLevel.saved(in: defaults), .info)
        defaults.set(true, forKey: "diagnosticsDebugCapture")
        XCTAssertEqual(DiagnosticCaptureLevel.saved(in: defaults), .debug)
        defaults.set("trace", forKey: "diagnosticsCaptureLevel")
        XCTAssertEqual(DiagnosticCaptureLevel.saved(in: defaults), .trace)
        defaults.set("info", forKey: "diagnosticsCaptureLevel")
        XCTAssertEqual(DiagnosticCaptureLevel.saved(in: defaults), .info)
    }

    func testProtobufIntegerStringsRoundTripWithoutLosingPrecision() throws {
        let data = Data(#"{"asset_amount":"18446744073709551615","amount_sat":"136000","enabled":false}"#.utf8)
        let value = try JSONDecoder().decode(DiagnosticValue.self, from: data)
        XCTAssertEqual(value["asset_amount"].text, "18446744073709551615")
        XCTAssertEqual(value["amount_sat"].int, 136000)
        XCTAssertFalse(value["enabled"].flag)
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticValue.self, from: Data(value.pretty.utf8)), value)
    }

    func testLogSearchIsCaseInsensitiveAndLiteral() {
        let record = DiagnosticLogRecord(id: "1", time: 1000, level: "INFO",
            source: "ROND", message: "ROUND quote.received · État prêt")
        XCTAssertTrue(record.matches("round"))
        XCTAssertTrue(record.matches("QuOtE"))
        XCTAssertTrue(record.matches("état"))
        XCTAssertTrue(record.matches("."))
        XCTAssertFalse(record.matches(".*"))
        XCTAssertFalse(record.matches("unrelated"))
        let highlighted = diagnosticHighlight("Round ROUND round", query: "round")
        XCTAssertEqual(String(highlighted.characters), "Round ROUND round")
        XCTAssertEqual(highlighted.runs.filter { $0.backgroundColor != nil }.count, 3)
        XCTAssertTrue(diagnosticLogExport([record]).contains("1970-01-01T00:00:01.000Z"))
    }

    func testShareKeepsCompleteVirtualAndAllBitcoinOutpoints() {
        let leaf = String(repeating: "ab", count: 32) + ":19"
        let first = String(repeating: "cd", count: 32) + ":7"
        let second = String(repeating: "ef", count: 32) + ":3"
        let value: DiagnosticValue = .object(["outpoint": .string(leaf), "amount_sat": .string("136000")])
        let anchors: [DiagnosticValue] = [
            .object(["Outpoint": .string(first), "AmountSat": .integer(200000), "PkScript": .string("5120")]),
            .object(["Outpoint": .string(second), "AmountSat": .integer(300000), "PkScript": .string("5121")])
        ]
        let shared = diagnosticVTXOShare(value, anchors: anchors)
        for point in [leaf, first, second] { XCTAssertTrue(shared.contains(point)) }
        XCTAssertFalse(shared.contains("…"))
        XCTAssertTrue(shared.contains("current spent status is not checked"))
    }

    func testExpiryUsesAuthoritativeThresholdsAndPreservesUnknown() {
        let value: DiagnosticValue = .object([
            "current_height": .integer(333120), "batch_expiry": .integer(333602),
            "refresh_threshold_blocks": .integer(1008), "critical_threshold_blocks": .integer(288),
            "relative_expiry": .integer(144), "blocks_remaining": .integer(482),
            "status": .string("VTXO_EXPIRY_STATUS_NEEDS_REFRESH")
        ])
        let window = DiagnosticExpiryWindow(value)
        XCTAssertEqual(window?.refreshStart, 332594)
        XCTAssertEqual(window?.criticalStart, 333314)
        XCTAssertEqual(window?.expiry, 333602)
        XCTAssertEqual(diagnosticExpiry(value), "482 blocks left")
        XCTAssertNil(DiagnosticExpiryWindow(.null))
        XCTAssertEqual(diagnosticExpiry(.null), "Expiry unknown")
    }

    func testBackgroundJournalPersistsActualResultsAndFirstExpiry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let journal = DiagnosticJournal(file: file)
        journal.begin(id: "expired", network: "signet", trigger: "Push")
        journal.event(id: "expired", network: "signet", label: "Cold startup")
        journal.finish(id: "expired", network: "signet", status: "iOS window expired")
        journal.finish(id: "expired", network: "signet", status: "Yielded")
        XCTAssertEqual(journal.runs.first?.status, "iOS window expired")
        journal.begin(id: "unfinished", network: "signet", trigger: "Push")
        journal.event(id: "unfinished", network: "signet", label: "Wallet prepared")
        let loaded = DiagnosticJournal(file: file)
        XCTAssertEqual(loaded.runs.first?.status, "iOS window expired")
        let interrupted = try XCTUnwrap(loaded.runs.last)
        XCTAssertEqual(interrupted.status, "End not recorded")
        XCTAssertEqual(interrupted.finished, interrupted.events.last?.time)
        XCTAssertFalse(loaded.entries.isEmpty)
    }

    func testTransferSummariesUseLocalDirectionAndKnownAmounts() {
        for direction in ["OOR_SESSION_DIRECTION_OUTGOING", "SWAP_DIRECTION_PAY"] {
            let summary = DiagnosticTransferSummary(.object([
                "direction": .string(direction), "amount_sat": .string("999")
            ]))
            XCTAssertEqual(summary.direction, "Outgoing")
            XCTAssertEqual(summary.amount, WalletFormatting.sats(999))
        }
        for direction in ["OOR_SESSION_DIRECTION_INCOMING", "SWAP_DIRECTION_RECEIVE"] {
            XCTAssertEqual(DiagnosticTransferSummary(.object([
                "direction": .string(direction), "amount_sat": .integer(500000)
            ])).direction, "Incoming")
        }
        XCTAssertEqual(DiagnosticTransferSummary(.object([
            "type": .string("CREDIT_OPERATION_TYPE_FUNDING")
        ])).direction, "To credit")
        XCTAssertEqual(DiagnosticTransferSummary(.object([
            "type": .string("CREDIT_OPERATION_TYPE_REDEMPTION")
        ])).direction, "From credit")
        XCTAssertEqual(DiagnosticTransferSummary(.null).amount, "Amount unavailable")
        XCTAssertEqual(DiagnosticTransferSummary(.null).direction, "Direction unknown")
        XCTAssertEqual(diagnosticFieldLabel("failed_before_ponr"), "Failed before funds were committed")
    }

    func testJournalRetriesProtectedHistoryBeforeSavingNewRuns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let old = DiagnosticJournal(file: file)
        old.begin(id: "before-reboot", network: "signet", trigger: "Push")
        old.finish(id: "before-reboot", network: "signet", status: "Yielded")
        var protected = true
        let next = DiagnosticJournal(file: file, read: { file in
            if protected { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: file)
        })
        next.begin(id: "after-reboot", network: "signet", trigger: "Push")
        XCTAssertEqual(DiagnosticJournal(file: file).runs.map(\.id), ["before-reboot"])
        protected = false
        next.event(id: "after-reboot", network: "signet", label: "Wallet prepared")
        let restored = DiagnosticJournal(file: file)
        XCTAssertEqual(Set(restored.runs.map(\.id)), ["before-reboot", "after-reboot"])
        XCTAssertEqual(next.runs.first { $0.id == "after-reboot" }?.status, "Running")
        XCTAssertEqual(restored.runs.first { $0.id == "before-reboot" }?.status, "Yielded")
    }

    func testDiagnosticRowsKeepIdentityWhenAnEarlierRowIsInserted() {
        let selected: DiagnosticValue = .object(["outpoint": .string("bb:7")])
        let before = diagnosticIdentified([selected], keys: ["outpoint"])
        let after = diagnosticIdentified([.object(["outpoint": .string("aa:0")]), selected], keys: ["outpoint"])
        XCTAssertEqual(before[0].id, after[1].id)
        XCTAssertNotEqual(after[0].id, after[1].id)
    }

    func testBrowsingLogWindowSurvivesPagingAndNativeEviction() {
        let old = (0..<600).map { DiagnosticLogRecord(id: "\($0)", time: Int64($0),
            level: "INFO", source: "Test", message: "Record \($0)") }
        let incoming = (600..<1200).map { DiagnosticLogRecord(id: "\($0)", time: Int64($0),
            level: "INFO", source: "Test", message: "Record \($0)") }
        var window = DiagnosticLogWindow()
        window.browse(old)
        let rowIDs = window.records(live: old).suffix(500).map(\.id)
        XCTAssertFalse(window.following)
        XCTAssertEqual(window.records(live: old + incoming).suffix(500).map(\.id), rowIDs)
        XCTAssertEqual(window.records(live: incoming).suffix(500).map(\.id), rowIDs)
        window.followLatest()
        XCTAssertTrue(window.following)
        XCTAssertEqual(window.records(live: incoming).map(\.id), incoming.map(\.id))
    }

    func testNativeInspectionRequiresStartedRuntime() async throws {
        do {
            _ = try await WalletClient().diagnosticRead(.vtxos)
            XCTFail("Diagnostics must not start or create a wallet")
        } catch let error as WalletError {
            XCTAssertTrue(error.message.contains("not started"), error.message)
        }
    }
}
