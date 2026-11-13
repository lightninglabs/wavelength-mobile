import XCTest
@testable import WalletKit
@testable import Wavelength

@MainActor
final class BatchExitTests: XCTestCase {
    func testPartialAdmissionAndMissingOrDuplicateResultsStayDistinct() throws {
        var operation = try operation()
        operation.apply(try result([
            ("a:0", "accepted"), ("b:1", "failed"), ("c:2", "new-value")
        ]))
        XCTAssertEqual(operation.inputs.map(\.state), [.queued, .failed, .checking, .checking])
        XCTAssertTrue(operation.isPending)
        XCTAssertEqual(operation.destination, "destination")
        var duplicate = try self.operation()
        duplicate.apply(try result([("a:0", "failed"), ("a:0", "accepted")]))
        XCTAssertEqual(duplicate.inputs[0].state, .checking)
    }

    func testReconciliationRequiresNewExactInputAndDestinationEvidence() throws {
        let now = Date(timeIntervalSince1970: 1_000.7)
        let old = try entry(id: "old", outpoint: "a:0", created: 900, status: "complete")
        var operation = BatchExitOperation(funds: try funds(), destination: "destination", activity: [old], now: now)
        operation.reconcile([
            old,
            try entry(id: "stale", outpoint: "a:0", created: 999, status: "complete"),
            try entry(id: "other-address", outpoint: "b:1", created: 1001, status: "failed", destination: "other"),
            try entry(id: "other-input", outpoint: "z:9", created: 1001, status: "complete")
        ])
        XCTAssertTrue(operation.inputs.allSatisfy { $0.state == .checking })
        let accepted = try entry(id: "new", outpoint: "a:0", created: 1000, status: "pending")
        operation.reconcile([accepted])
        XCTAssertEqual(operation.inputs[0].state, .queued)
        XCTAssertEqual(operation.inputs[0].entryID, "new")
        // Absence in a truncated or lagging list is not rejection.
        operation.reconcile([])
        XCTAssertEqual(operation.inputs[0].state, .queued)
        operation.reconcile([try entry(id: "new", outpoint: "a:0", created: 1000, status: "complete")])
        XCTAssertEqual(operation.inputs[0].state, .complete)
        XCTAssertEqual(operation.inputs[1].state, .checking)
    }

    func testOwnWalletLostResponseCanReconcileButNeverFromUnilateralActivity() throws {
        var operation = BatchExitOperation(funds: try funds(), destination: "", activity: [],
            now: Date(timeIntervalSince1970: 1000))
        let unilateral = try entry(id: "recovery", outpoint: "a:0", created: 1001, status: "complete", counterparty: "unilateral")
        operation.reconcile([unilateral])
        XCTAssertEqual(operation.inputs[0].state, .checking)
        operation.reconcile([try entry(id: "cooperative", outpoint: "a:0", created: 1001, status: "complete")])
        XCTAssertEqual(operation.inputs[0].state, .complete)
    }

    func testAggregateActivityCompletesOnlyItsAcceptedSubset() throws {
        var operation = try operation()
        operation.apply(try result([("a:0", "accepted"), ("b:1", "accepted"), ("c:2", "unknown"), ("d:3", "failed")],
                                   activityID: "batch-activity"))
        XCTAssertEqual(operation.inputs.map(\.entryID), ["batch-activity", "batch-activity", nil, nil])
        operation.reconcile([try entry(id: "batch-activity", outpoint: "a:0", created: 1001,
                                       status: "complete", amount: 4000)])
        XCTAssertEqual(operation.inputs.map(\.state), [.complete, .complete, .checking, .failed])
    }

    func testLostWholeBatchResponseRecoversItsHandleWithoutGuessingAPartialSubset() throws {
        var operation = BatchExitOperation(funds: try funds(), destination: "", activity: [],
            now: Date(timeIntervalSince1970: 1000))
        let aggregate = try entry(id: "batch-exit-native", outpoint: "a:0", created: 1001,
                                  status: "complete", amount: 8000)
        operation.reconcile([aggregate])
        XCTAssertEqual(operation.activityID, "batch-exit-native")
        XCTAssertEqual(operation.destination, "destination")
        XCTAssertTrue(operation.inputs.allSatisfy { $0.state == .complete })

        var partial = BatchExitOperation(funds: try funds(), destination: "destination", activity: [],
            now: Date(timeIntervalSince1970: 1000))
        partial.reconcile([try entry(id: "batch-exit-partial", outpoint: "a:0", created: 1001,
                                     status: "complete", amount: 4000)])
        XCTAssertNil(partial.activityID)
        XCTAssertTrue(partial.inputs.allSatisfy { $0.state == .checking })
    }

    func testOneDispatchIsPersistedBeforeResponseLossAndNeverReplayedOnRestart() async throws {
        try await withFixture { defaults, root in
            let selected = try self.funds()
            var calls = 0
            let url = root.appendingPathComponent("Wavelength/signet/cooperative-exits.json")
            let store = self.store(defaults, root) { outpoints, destination in
                calls += 1
                XCTAssertEqual(outpoints, selected.map(\.outpoint))
                XCTAssertEqual(destination, "destination")
                let persisted = try BatchExitJournal.load(url)
                XCTAssertEqual(persisted.count, 1)
                XCTAssertTrue(persisted[0].inputs.allSatisfy { $0.state == .checking })
                throw WalletError(message: "response lost after admission")
            }
            _ = try await store.exitBatch(funds: selected, destination: "destination")
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(store.pendingExitOutpoints, Set(selected.map(\.outpoint)))
            let reopened = self.store(defaults, root) { _, _ in
                calls += 1
                return try self.result([])
            }
            XCTAssertEqual(reopened.exitBatches.count, 1)
            XCTAssertEqual(reopened.exitBatches[0].error, "response lost after admission")
            do {
                _ = try await reopened.exitBatch(funds: selected, destination: "destination")
                XCTFail("An unresolved input must not be resubmitted")
            } catch { }
            XCTAssertEqual(calls, 1)
            defaults.set("mainnet", forKey: "selectedNetwork")
            let mainnet = self.store(defaults, root) { _, _ in try self.result([]) }
            XCTAssertTrue(mainnet.exitBatches.isEmpty)
        }
    }

    func testDefinitiveFailureDoesNotBlockExplicitNewSelection() async throws {
        try await withFixture { defaults, root in
            var calls = 0
            let store = self.store(defaults, root) { _, _ in
                calls += 1
                throw WalletError(message: "exit batch (do not retry without reconciling admission): rpc error: code = FailedPrecondition desc = input unavailable")
            }
            _ = try await store.exitBatch(funds: try self.funds(), destination: "destination")
            XCTAssertTrue(store.pendingExitOutpoints.isEmpty)
            XCTAssertTrue(store.exitBatches[0].inputs.allSatisfy { $0.state == .failed })
            XCTAssertEqual(calls, 1, "A failed request must not retry itself")
        }
        XCTAssertFalse(WalletError(message: "exit batch (do not retry without reconciling admission): rpc error: code = Internal desc = rpc error: code = InvalidArgument desc = nested").isExitBatchRejectedBeforeAdmission)
        XCTAssertFalse(WalletError(message: "context deadline exceeded").isExitBatchRejectedBeforeAdmission)
    }

    func testPartialResponsePersistsAndOnlyDefinitivelyRejectedInputsCanBeSelectedAgain() async throws {
        try await withFixture { defaults, root in
            let inputs = Array(try self.funds().prefix(2))
            var calls = 0
            let store = self.store(defaults, root) { _, _ in
                calls += 1
                return try self.result([("a:0", "accepted"), ("b:1", "failed")])
            }
            _ = try await store.exitBatch(funds: inputs, destination: "destination")
            let reopened = self.store(defaults, root) { outpoints, _ in
                calls += 1
                XCTAssertEqual(outpoints, ["b:1"])
                return try self.result([("b:1", "accepted")])
            }
            XCTAssertEqual(reopened.exitBatches[0].inputs.map(\.state), [.queued, .failed])
            XCTAssertEqual(reopened.pendingExitOutpoints, ["a:0"])
            _ = try await reopened.exitBatch(funds: [inputs[1]], destination: "destination")
            XCTAssertEqual(calls, 2, "Only the explicit second action submits the rejected input")
            XCTAssertEqual(reopened.pendingExitOutpoints, ["a:0", "b:1"])
        }
    }

    func testCorruptJournalAndPreDispatchPersistenceFailureNeverDispatch() async throws {
        try await withFixture { defaults, root in
            let url = root.appendingPathComponent("Wavelength/signet/cooperative-exits.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("broken".utf8).write(to: url)
            var calls = 0
            let store = self.store(defaults, root) { _, _ in calls += 1; return try self.result([]) }
            XCTAssertNotNil(store.exitBatchJournalError)
            store.reconcileExitBatches()
            XCTAssertEqual(try Data(contentsOf: url), Data("broken".utf8))
            do { _ = try await store.exitBatch(funds: try self.funds(), destination: ""); XCTFail() }
            catch { }
            XCTAssertEqual(calls, 0)
            // A directory occupying the journal path prevents atomic receipt persistence.
            try FileManager.default.removeItem(at: url)
            let fresh = self.store(defaults, root) { _, _ in calls += 1; return try self.result([]) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            do { _ = try await fresh.exitBatch(funds: try self.funds(), destination: ""); XCTFail() }
            catch { }
            XCTAssertTrue(fresh.exitBatches.isEmpty)
            XCTAssertEqual(calls, 0)
        }
    }

    func testPostDispatchWriteFailureRetriesSavingAuthoritativePartialResults() async throws {
        try await withFixture { defaults, root in
            let url = root.appendingPathComponent("Wavelength/signet/cooperative-exits.json")
            var beforeDispatch = Data()
            var calls = 0
            let store = self.store(defaults, root) { _, _ in
                calls += 1
                beforeDispatch = try Data(contentsOf: url)
                // Simulate the post-admission journal write being unavailable.
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return try self.result([("a:0", "accepted"), ("b:1", "failed")], activityID: "native")
            }
            _ = try await store.exitBatch(funds: Array(try self.funds().prefix(2)), destination: "destination")
            XCTAssertNotNil(store.exitBatchJournalError)
            XCTAssertEqual(store.exitBatches[0].inputs.map(\.state), [.queued, .failed])
            try FileManager.default.removeItem(at: url)
            try beforeDispatch.write(to: url)
            store.reconcileExitBatches()
            XCTAssertNil(store.exitBatchJournalError)
            let reopened = self.store(defaults, root) { _, _ in XCTFail("Must not replay"); return try self.result([]) }
            XCTAssertEqual(reopened.exitBatches[0].activityID, "native")
            XCTAssertEqual(reopened.exitBatches[0].inputs.map(\.state), [.queued, .failed])
            XCTAssertEqual(calls, 1)
        }
    }

    func testCombinedFeeRequiresEveryExactInputAndEveryOutputToBeEconomic() throws {
        let inputs = Array(try funds().prefix(2))
        let valid = [try quote("a:0", fee: 0), try quote("b:1", fee: 42)]
        let fee = try BatchExitFee(funds: inputs, estimates: valid)
        XCTAssertEqual(fee.totalSat, 42)
        XCTAssertTrue(fee.canExit)
        XCTAssertThrowsError(try BatchExitFee(funds: inputs, estimates: Array(valid.prefix(1))))
        XCTAssertFalse(try BatchExitFee(funds: inputs, estimates: [valid[0], quote("b:1", fee: 2000)]).canExit)
    }

    private func store(_ defaults: UserDefaults, _ root: URL,
                       submit: @escaping ([String], String) async throws -> ExitBatchResult) -> WalletStore {
        WalletStore(defaults: defaults, dataRoot: root, applicationIsActive: { true }, submitExitBatch: submit)
    }

    private func withFixture(_ body: (UserDefaults, URL) async throws -> Void) async throws {
        let suite = "batch-exit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defaults.set("signet", forKey: "selectedNetwork")
        defaults.set(false, forKey: "biometricUnlockEnabled")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try await body(defaults, root)
    }

    private func funds() throws -> [WalletVTXO] {
        try ["a:0", "b:1", "c:2", "d:3"].map { outpoint in
            try decode(["Outpoint": outpoint, "AmountSat": 2000, "Status": "live", "CommitmentTxid": ""])
        }
    }
    private func operation() throws -> BatchExitOperation {
        BatchExitOperation(funds: try funds(), destination: "", activity: [])
    }
    private func result(_ outcomes: [(String, String)], activityID: String = "") throws -> ExitBatchResult {
        try decode(["Destination": "destination", "ActivityID": activityID, "Results": outcomes.map {
            ["Outpoint": $0.0, "Outcome": $0.1, "Error": ""]
        }])
    }
    private func quote(_ outpoint: String, fee: Int64) throws -> ExitFeeEstimate {
        try decode(["Outpoint": outpoint, "AmountSat": 2000, "EstimatedFeeSat": fee, "BelowDustWarning": false])
    }
    private func entry(id: String, outpoint: String, created: TimeInterval, status: String,
                       destination: String = "destination", counterparty: String = "", amount: Int64 = 2000) throws -> Entry {
        try decode(["ID": id, "Kind": "exit", "Status": status, "AmountSat": -amount, "FeeSat": 0,
            "Counterparty": counterparty, "Note": "",
            "CreatedAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: created)),
            "Progress": ["Phase": "pending", "PhaseLabel": "pending", "PaymentHash": "", "Txid": "",
                "ConfirmationHeight": 0, "VTXOOutpoint": outpoint, "Preimage": ""],
            "Request": ["Type": "onchain", "OnchainAddress": destination, "LightningInvoice": "",
                "PaymentHash": "", "ArkAddress": ""]])
    }
    private func decode<T: Decodable>(_ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
