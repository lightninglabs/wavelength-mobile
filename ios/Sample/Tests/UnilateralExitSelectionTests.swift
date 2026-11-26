import XCTest
import WalletKit
@testable import Wavelength

@MainActor
final class UnilateralExitSelectionTests: XCTestCase {
    private let selected = ["a:0", "b:1", "c:2"]

    func testStartsReviewedSelectionAndStopsAfterUnconfirmedReply() async throws {
        let reply = try exitReply()
        var submitted: [String] = []
        let store = makeStore(plan: try plan(), submit: { outpoint, _ in
            submitted.append(outpoint)
            if outpoint == "b:1" { throw WalletActionError(message: "Reply lost") }
            return reply
        })

        var states: [String: String] = [:]
        try await store.startUnilateralExits(outpoints: selected, reviewedFeeRate: 2) { outpoint, admission in
            states[outpoint] = admission.title
        }

        XCTAssertEqual(submitted, ["a:0", "b:1"])
        XCTAssertEqual(states["a:0"], "Started")
        XCTAssertEqual(states["b:1"], "Check exit status")
        XCTAssertNil(states["c:2"])
    }

    func testStartsEveryReviewedOutpointWhenAllAreAccepted() async throws {
        var submitted: [String] = []
        let reply = try exitReply()
        let store = makeStore(plan: try plan(), submit: { outpoint, _ in
            submitted.append(outpoint)
            return reply
        })
        try await store.startUnilateralExits(outpoints: selected, reviewedFeeRate: 2) { _, _ in }
        XCTAssertEqual(submitted, selected)
    }

    func testChangedQuoteOrIncompletePlanStartsNothing() async throws {
        let responses = try [
            plan(feeRate: 3),
            plan(outpoints: ["a:0", "c:2"]),
            plan(invalid: "b:1")
        ]
        for response in responses {
            let store = makeStore(plan: response, submit: { _, _ in
                XCTFail("The whole reviewed selection must be ready before the first exit")
                return try self.exitReply()
            })
            do {
                try await store.startUnilateralExits(outpoints: selected, reviewedFeeRate: 2) { _, _ in
                    XCTFail("Must reject before making any exit attempt")
                }
                XCTFail("Expected the reviewed plan to be rejected")
            } catch let error as WalletActionError {
                XCTAssertTrue(error.message.contains("plan") || error.message.contains("selected funds"))
            }
        }
    }

    func testCustomTermsAreRequotedAndForwardedForEveryExit() async throws {
        let options = UnilateralExitOptions(sweepAddress: "test-address", feeRateSatPerVByte: 7)
        let response = try plan(feeRate: 7, sweepAddress: options.sweepAddress)
        let reply = try exitReply()
        var requested: [String] = []
        let store = makeStore(plan: response, expectedOptions: options, submit: { outpoint, actual in
            XCTAssertEqual(actual, options)
            requested.append(outpoint)
            return reply
        })

        try await store.startUnilateralExits(outpoints: selected, options: options, reviewedFeeRate: 7) { _, _ in }
        XCTAssertEqual(requested, selected)
    }

    func testPlanRejectsAddressOrFeeMissingFromNativeReply() throws {
        let response = try plan()
        XCTAssertThrowsError(try UnilateralExitSelectionPlan(plan: response, outpoints: selected,
            options: .init(sweepAddress: "test-address")))
        XCTAssertThrowsError(try UnilateralExitSelectionPlan(plan: response, outpoints: selected,
            options: .init(feeRateSatPerVByte: 7)))
    }

    private func makeStore(plan: ExitPlan, expectedOptions: UnilateralExitOptions = .init(),
                           submit: @escaping (String, UnilateralExitOptions) async throws -> ExitResult) -> WalletStore {
        let suiteName = "UnilateralExitSelectionTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return WalletStore(defaults: defaults, applicationIsActive: { true },
                           readUnilateralPlan: { outpoints, options in
            XCTAssertEqual(outpoints, self.selected)
            XCTAssertEqual(options, expectedOptions)
            return plan
        }, submitUnilateralExit: submit)
    }

    private func plan(feeRate: Int = 2, outpoints: [String]? = nil, invalid: String? = nil,
                      sweepAddress: String = "") throws -> ExitPlan {
        let entries: [[String: Any]] = (outpoints ?? selected).map { outpoint in
            ["Outpoint": outpoint, "FundingAddress": "", "RequiredConfirmations": 1,
             "RequiredFeeUTXOCount": 1, "UsableFeeUTXOCount": 1, "RecommendedUTXOAmountSat": 10000,
             "FundingShortfallSat": 0, "CanStart": outpoint != invalid, "InfeasibilityReason": "",
             "ExitJobFound": false, "ExitStatus": "", "LastError": "", "RoundCommitment": "",
             "Err": outpoint == invalid ? "No unilateral-exit ancestry" : ""]
        }
        return try JSONDecoder().decode(ExitPlan.self, from: JSONSerialization.data(withJSONObject:
            ["Plans": entries, "CanStart": true, "FeeRateSatPerVByte": feeRate,
             "SweepAddress": sweepAddress, "TotalEstimatedFeeSat": feeRate * 1000,
             "TotalFundingShortfallSat": 0, "TotalRecommendedFundingSat": 0]))
    }

    private func exitReply() throws -> ExitResult {
        try JSONDecoder().decode(ExitResult.self, from: Data(
            #"{"Path":"unilateral","Cooperative":false,"QueuedOutpoints":[],"Created":true,"ActorID":"fixture"}"#.utf8))
    }
}
