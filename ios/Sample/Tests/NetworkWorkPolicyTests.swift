import XCTest
import WalletKit
@testable import Wavelength

@MainActor
final class NetworkWorkPolicyTests: XCTestCase {
    func testUnresolvedRefreshDoesNotReplaceItsNetworkOrEndpoints() async throws {
        for status in ["Checking status", "In progress", "Action needed"] {
            let suite = "network-work-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("signet", forKey: "selectedNetwork")
            defaults.set(try JSONEncoder().encode(RefreshOperation(outpoints: ["selected-input:0"],
                amountSat: 1000, status: status)), forKey: "signet.refresh")
            var transportChanges = 0
            let store = WalletStore(defaults: defaults, applicationIsActive: { true },
                startClient: { _ in transportChanges += 1 }, stopClient: { transportChanges += 1 })
            XCTAssertTrue(store.canChangeNetwork, "No native call is active; the persisted refresh is the guard")
            XCTAssertNotNil(store.networkSwitchBlockedReason)
            let changed = await store.switchNetwork(to: .mainnet)
            XCTAssertFalse(changed)
            XCTAssertEqual(store.network, .signet)
            XCTAssertEqual(defaults.string(forKey: "selectedNetwork"), "signet")
            XCTAssertEqual(transportChanges, 0)
            await store.saveEndpointOverrides(operatorAddress: "other.example:443", swapServerAddress: "", esploraURL: "")
            XCTAssertEqual(store.operatorAddress, "")
            XCTAssertEqual(transportChanges, 0)
            XCTAssertEqual(store.refreshOperation?.status, status)
        }
    }

    func testPositiveCompletionOrReleaseAllowsSelectingAnotherWallet() async throws {
        for operation in [
            RefreshOperation(outpoints: ["selected-input:0"], amountSat: 1000, status: "Complete"),
            RefreshOperation(outpoints: ["selected-input:0"], amountSat: 1000, status: "Action needed", canRetry: true),
        ] {
            let suite = "network-released-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            defaults.set("signet", forKey: "selectedNetwork")
            defaults.set(try JSONEncoder().encode(operation), forKey: "signet.refresh")
            var stops = 0
            let store = WalletStore(defaults: defaults, dataRoot: root, applicationIsActive: { true },
                startClient: { _ in }, stopClient: { stops += 1 })
            XCTAssertNil(store.networkSwitchBlockedReason)
            let changed = await store.switchNetwork(to: .mainnet)
            XCTAssertTrue(changed)
            XCTAssertEqual(store.network, .mainnet)
            XCTAssertEqual(defaults.string(forKey: "selectedNetwork"), "mainnet")
            XCTAssertEqual(stops, 1)
            // Selecting another wallet preserves the old refresh evidence.
            XCTAssertNotNil(defaults.data(forKey: "signet.refresh"))
        }
    }
}
