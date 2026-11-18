import XCTest
import WalletKit
@testable import Wavelength

@MainActor
final class BackgroundTraceTests: XCTestCase {
    func testProducerMetadataIsOptionalAndUsesOnlyKnownReasons() throws {
        let deadline: Int64 = 1_800_000_000
        let wake = try XCTUnwrap(DiagnosticProducerWake(payload: [
            "wake_reason": "scheduled_round", "wake_deadline_unix": deadline
        ]))
        XCTAssertEqual(wake.deadline, deadline)
        XCTAssertEqual(wake.reason?.deadlineLabel, "Registration closes")
        XCTAssertEqual(diagnosticTime(try XCTUnwrap(wake.deadline), milliseconds: false),
                       Date(timeIntervalSince1970: Double(deadline)).formatted(date: .abbreviated, time: .standard))
        XCTAssertNil(DiagnosticProducerWake(payload: ["wake_reason": "future"]))
        XCTAssertNil(DiagnosticProducerWake(payload: ["wake_deadline_unix": deadline]))
        for invalid: Any in [true, 0, -1, 1.25, "1800000000", Double.infinity] {
            let signing = DiagnosticProducerWake(payload: ["wake_reason": "round_signing", "wake_deadline_unix": invalid])
            XCTAssertEqual(signing?.reason, .roundSigning)
            XCTAssertNil(signing?.deadline)
        }
        XCTAssertNil(DiagnosticProducerWake(payload: [
            "wake_reason": "mailbox_update", "wake_deadline_unix": deadline
        ])?.deadline)
    }

    func testWaitExpiryRetainsOwnerAndStopReasonAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let journal = DiagnosticJournal(file: file)
        journal.begin(id: "expired", network: "signet", trigger: "Relay wake")
        journal.wait(id: "expired", network: "signet", behind: "owner")
        journal.observeExpiry(id: "expired", reason: "iOS window expired")
        journal.endWait(id: "expired", network: "signet", expired: true)
        journal.finish(id: "expired", network: "signet", status: "No native window")
        let restored = try XCTUnwrap(DiagnosticJournal(file: file).runs.first)
        XCTAssertEqual(restored.waitedBehind, "owner")
        XCTAssertEqual(restored.outcomeLabel, "Expired while waiting")
        XCTAssertEqual(restored.events.last?.label, "iOS window expired")
        XCTAssertTrue(restored.wakeReasonUnavailable)

        journal.begin(id: "later", network: "signet", trigger: "Relay wake")
        journal.wait(id: "later", network: "signet", behind: "owner")
        journal.endWait(id: "later", network: "signet", expired: false)
        journal.observeExpiry(id: "later", reason: "Fallback deadline reached")
        let admitted = try XCTUnwrap(journal.runs.last)
        XCTAssertFalse(admitted.endedWhileWaiting)
        XCTAssertEqual(admitted.outcomeLabel, "Fallback deadline reached")
    }

    func testLegacyRunRemainsReadableWithoutInventingMeasurements() throws {
        let data = Data(#"{"id":"old","network":"signet","started":1000,"trigger":"Push","finished":2000,"status":"Yielded","events":[{"time":1000,"label":"Wake received"}]}"#.utf8)
        let run = try JSONDecoder().decode(DiagnosticRun.self, from: data)
        XCTAssertNil(run.wake)
        XCTAssertNil(run.startup)
        XCTAssertNil(run.nativeBudgetSeconds)
        XCTAssertNil(run.events[0].durationMilliseconds)
        XCTAssertEqual(run.logUntil, 2000)
    }

    func testMonotonicSpansAndLateNativeResultsPreserveFirstTerminalOutcome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var uptime = 100.0
        let file = directory.appendingPathComponent("journal.json")
        let journal = DiagnosticJournal(file: file, uptime: { uptime })
        journal.begin(id: "window", network: "signet", trigger: "Scheduled refresh",
                      wake: .init(entryPoint: "BGAppRefreshTask", taskID: "maintenance"))
        journal.context(id: "window", startup: "Cold", nativeBudget: 15)
        uptime += 0.25
        let value = await journal.measure(id: "window", network: "signet", label: "Daemon startup") {
            uptime += 1.5
            return 7
        }
        XCTAssertEqual(value, 7)
        journal.finish(id: "window", network: "signet", status: "iOS window expired")
        uptime += 2
        _ = await journal.measure(id: "window", network: "signet", label: "Native cleanup") { true }
        let result = try JSONDecoder().decode(ReceiptWindowResult.self, from: Data(#"{"receipts":[],"batches":7,"needs_foreground":true,"interrupted":true,"budget_exhausted":false,"maintenance_checked":4,"maintenance_deferred":true,"maintenance_more":true}"#.utf8))
        journal.finish(id: "window", network: "signet", result: result)
        let run = try XCTUnwrap(journal.runs.first)
        XCTAssertEqual(run.status, "iOS window expired")
        XCTAssertEqual(run.elapsedAtFinish, 1750)
        XCTAssertEqual(run.events.first { $0.label == "Daemon startup" }?.durationMilliseconds, 1500)
        XCTAssertEqual(run.observedDuration, 3.75)
        XCTAssertEqual(run.batches, 7)
        XCTAssertEqual(run.checked, 4)
        XCTAssertEqual(run.deferred, true)
        XCTAssertEqual(run.more, true)
        XCTAssertEqual(run.needsForeground, true)
        XCTAssertEqual(run.receiptProofs, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(run.logUntil), try XCTUnwrap(run.finished))
        let restored = DiagnosticJournal(file: file)
        XCTAssertEqual(restored.runs.first?.wake?.entryPoint, "BGAppRefreshTask")
        XCTAssertEqual(restored.runs.first?.startup, "Cold")
        XCTAssertEqual(restored.runs.first?.checked, 4)
    }

    func testFailedSpanRecordsStageWithoutSavingErrorText() async throws {
        enum Failure: Error { case secret }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let journal = DiagnosticJournal(file: file)
        journal.begin(id: "failed", network: "signet", trigger: "Relay wake")
        do {
            _ = try await journal.measure(id: "failed", network: "signet", label: "Credential read") { throw Failure.secret }
            XCTFail("Expected the original error")
        } catch Failure.secret { }
        XCTAssertEqual(journal.runs.first?.events.last?.label, "Credential read failed")
        XCTAssertFalse(journal.runs.first!.pretty.contains("secret"))
        do {
            _ = try journal.measureSync(id: "failed", network: "signet", label: "Sync read") { throw Failure.secret }
            XCTFail("Expected the original synchronous error")
        } catch Failure.secret { }
        XCTAssertEqual(journal.runs.first?.events.last?.label, "Sync read failed")
        XCTAssertFalse(journal.runs.first!.pretty.contains("secret"))
    }
}
