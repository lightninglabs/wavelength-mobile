import XCTest
import WalletKit
@testable import Wavelength

@MainActor
final class RefreshReconciliationTests: XCTestCase {
    func testPartialSettlementReconcilesLegacySelectionAndReleasesNetworkGuard() async throws {
        let suite = "partial-refresh-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let inputs = (0..<12).map { "input-\($0):0" }
        let original = RefreshOperation(outpoints: inputs, amountSat: 12000, status: "In progress")
        defaults.set("signet", forKey: "selectedNetwork")
        defaults.set(try JSONEncoder().encode(original), forKey: "signet.refresh")
        var observed: [String] = []
        var stops = 0
        let store = WalletStore(defaults: defaults, dataRoot: root, applicationIsActive: { true },
            startClient: { _ in }, stopClient: { stops += 1 }, observeRefresh: { selected in
                observed = selected
                return try self.observation(confirmed: 8, retry: true, remaining: Array(inputs[8...]))
            })
        XCTAssertNotNil(store.networkSwitchBlockedReason)
        await store.checkRefreshStatus()
        XCTAssertEqual(observed, inputs)
        XCTAssertEqual(store.refreshOperation?.status, "Partially refreshed")
        XCTAssertEqual(store.refreshOperation?.confirmedAmountSat, 8000)
        XCTAssertEqual(store.refreshOperation?.remainingAmountSat, 4000)
        XCTAssertEqual(store.refreshOperation?.outpoints, inputs, "The original request stays intact")
        XCTAssertEqual(store.refreshOperation?.remainingOutpoints, Array(inputs[8...]))
        XCTAssertEqual(store.refreshOperation?.unresolvedInputCount, 0)
        XCTAssertNil(store.networkSwitchBlockedReason)
        XCTAssertNil(store.refreshCheckError)
        XCTAssertFalse(store.isCheckingRefresh)
        XCTAssertEqual(stops, 0, "Observation does not restart or resubmit anything")

        let reopened = WalletStore(defaults: defaults, dataRoot: root)
        XCTAssertEqual(reopened.refreshOperation?.status, "Partially refreshed")
        XCTAssertEqual(reopened.refreshOperation?.remainingOutpoints, Array(inputs[8...]))
        let changed = await store.switchNetwork(to: .mainnet)
        XCTAssertTrue(changed)
        XCTAssertEqual(store.network, .mainnet)
        let saved = try JSONDecoder().decode(RefreshOperation.self, from: XCTUnwrap(defaults.data(forKey: "signet.refresh")))
        XCTAssertEqual(saved.outpoints, inputs)
        XCTAssertEqual(saved.confirmedCount, 8)
    }

    func testRestartDropsOldCheckAndAdmitsAnotherCheckOnTheSameNetwork() async throws {
        let suite = "restart-refresh-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set("signet", forKey: "selectedNetwork")
        // A pre-upgrade operation has no identifier or progress fields.
        defaults.set(Data(#"{"outpoints":["old:0","remaining:0"],"amountSat":2000,"status":"In progress"}"#.utf8), forKey: "signet.refresh")
        var pending: CheckedContinuation<RefreshObservation, Error>?
        var reads = 0
        let store = WalletStore(defaults: defaults, dataRoot: root,
            startClient: { _ in }, stopClient: {}, observeRefresh: { _ in
                reads += 1
                if reads == 1 {
                    return try await withCheckedThrowingContinuation { pending = $0 }
                }
                return try self.observation(confirmed: 1, retry: true, remaining: ["remaining:0"], total: 2, refreshed: 1000, available: 1000)
            })
        let old = Task { await store.checkRefreshStatus() }
        while pending == nil { await Task.yield() }
        XCTAssertTrue(store.isCheckingRefresh)
        await store.start()
        XCTAssertFalse(store.isCheckingRefresh)
        pending?.resume(returning: try observation(confirmed: 1, retry: true, remaining: ["remaining:0"], total: 2, refreshed: 1000, available: 1000))
        await old.value
        XCTAssertEqual(store.refreshOperation?.status, "In progress", "The old runtime cannot release the new runtime's guard")
        await store.checkRefreshStatus()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(store.refreshOperation?.status, "Partially refreshed")
        XCTAssertFalse(store.isCheckingRefresh)
    }

    func testUnresolvedOrFailedObservationRetainsEvidenceAndNetworkGuard() async throws {
        for fails in [false, true] {
            let suite = "unresolved-refresh-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("signet", forKey: "selectedNetwork")
            let original = RefreshOperation(outpoints: ["settled:0", "unknown:0"], amountSat: 2000, status: "In progress")
            defaults.set(try JSONEncoder().encode(original), forKey: "signet.refresh")
            let store = WalletStore(defaults: defaults, observeRefresh: { _ in
                if fails { throw WalletActionError(message: "Local read failed") }
                return try self.observation(confirmed: 1, retry: false, remaining: [], total: 2, refreshed: 1000, available: 0)
            })
            await store.checkRefreshStatus()
            XCTAssertNotNil(store.networkSwitchBlockedReason)
            XCTAssertEqual(store.refreshOperation?.status, "In progress")
            XCTAssertEqual(store.refreshOperation?.outpoints, original.outpoints)
            XCTAssertEqual(store.refreshCheckError != nil, fails)
            XCTAssertFalse(store.isCheckingRefresh)
            if fails {
                let failures = DiagnosticJournal.shared.entries.filter { $0.message == "Refresh status check failed" }.count
                await store.checkRefreshStatus()
                XCTAssertEqual(DiagnosticJournal.shared.entries.filter { $0.message == "Refresh status check failed" }.count, failures,
                               "Repeated failed polls must not evict useful host-log history")
            }
        }
    }

    private func observation(confirmed: Int, retry: Bool, remaining: [String], total: Int = 12,
                             refreshed: Int64 = 8000, available: Int64 = 4000) throws -> RefreshObservation {
        let object: [String: Any] = ["Complete": false, "RetryAllowed": retry, "ConfirmedCount": confirmed,
            "ConfirmedAmountSat": refreshed, "Total": total, "RemainingOutpoints": remaining, "RemainingAmountSat": available]
        return try JSONDecoder().decode(RefreshObservation.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
