import XCTest
import WalletKit
@testable import Wavelength

final class WalletConfigurationTests: XCTestCase {
    func testNetworkConfigsUseLightweightWallet() throws {
        for network in WalletNetwork.allCases {
            let config = WalletConfig.network(network, dataDir: "/tmp/\(network.rawValue)")
            let object = try encodedObject(config)

            XCTAssertEqual(object["network"] as? String, network.rawValue)
            XCTAssertEqual(object["wallet_type"] as? String, "lwwallet")
            let expectedPollInterval: Int = network == .regtest ? 1 :
                (network == .mainnet ? 30 : 10)
            XCTAssertEqual(object["wallet_poll_interval_seconds"] as? Int, expectedPollInterval)
            XCTAssertNil(object["wallet_esplora_url"])
            XCTAssertNil(object["server_address"])
            XCTAssertNil(object["swap_server_address"])
            XCTAssertEqual(object["allow_mainnet"] as? Bool, network == .mainnet)
            XCTAssertEqual(object["server_insecure"] as? Bool, network == .regtest ? true : nil)
            XCTAssertEqual(object["swap_server_insecure"] as? Bool, network == .regtest ? true : nil)
        }
    }

    func testCustomEndpointsAreEncoded() throws {
        let config = WalletConfig.network(
            .mainnet,
            dataDir: "/tmp/mainnet",
            esploraURL: "https://esplora.example/api",
            operatorAddress: "ark.example:443",
            swapServerAddress: "swap.example:443"
        )
        let object = try encodedObject(config)

        XCTAssertEqual(object["wallet_esplora_url"] as? String, "https://esplora.example/api")
        XCTAssertEqual(object["server_address"] as? String, "ark.example:443")
        XCTAssertEqual(object["swap_server_address"] as? String, "swap.example:443")
        XCTAssertEqual(object["server_transport"] as? String, "grpc")
        XCTAssertEqual(object["allow_mainnet"] as? Bool, true)
    }

    func testHTTPRegtestEndpointsSelectInsecureREST() throws {
        let config = WalletConfig.network(
            .regtest,
            dataDir: "/tmp/regtest",
            esploraURL: "http://127.0.0.1:3002",
            operatorAddress: "http://127.0.0.1:7070",
            swapServerAddress: "http://127.0.0.1:10030"
        )
        let object = try encodedObject(config)

        XCTAssertEqual(object["server_transport"] as? String, "rest")
        XCTAssertEqual(object["server_insecure"] as? Bool, true)
        XCTAssertEqual(object["swap_server_transport"] as? String, "rest")
        XCTAssertEqual(object["swap_server_insecure"] as? Bool, true)
    }

    func testCertificatePathsKeepRegtestTLS() throws {
        let config = WalletConfig.network(
            .regtest,
            dataDir: "/tmp/regtest",
            operatorAddress: "127.0.0.1:7070",
            swapServerAddress: "127.0.0.1:10029",
            operatorTLSCertPath: "/tmp/operator.cert",
            swapTLSCertPath: "/tmp/swap.cert"
        )
        let object = try encodedObject(config)

        XCTAssertEqual(object["server_transport"] as? String, "grpc")
        XCTAssertEqual(object["server_tls_cert_path"] as? String, "/tmp/operator.cert")
        XCTAssertNil(object["server_insecure"])
        XCTAssertEqual(object["swap_server_tls_cert_path"] as? String, "/tmp/swap.cert")
        XCTAssertNil(object["swap_server_insecure"])
    }

    @MainActor
    func testMainnetReceiveUsesDefaultsWithoutOverrides() throws {
        let suite = "connection-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("mainnet", forKey: "selectedNetwork")
        let store = WalletStore(defaults: defaults)
        XCTAssertTrue(store.operatorAddress.isEmpty)
        XCTAssertTrue(store.swapServerAddress.isEmpty)
        XCTAssertTrue(store.operatorAvailable, "Boarding must accept the SDK operator default")
        XCTAssertTrue(store.offchainAvailable, "Lightning receive must accept the SDK swap default")
    }

    @MainActor
    func testRegtestStillRequiresExplicitServices() throws {
        let suite = "connection-regtest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("regtest", forKey: "selectedNetwork")
        XCTAssertFalse(WalletStore(defaults: defaults).operatorAvailable)
        defaults.set("127.0.0.1:10010", forKey: "regtest.operatorAddress")
        let operatorOnly = WalletStore(defaults: defaults)
        XCTAssertTrue(operatorOnly.operatorAvailable)
        XCTAssertFalse(operatorOnly.offchainAvailable)
        defaults.set("127.0.0.1:10030", forKey: "regtest.swapAddress")
        XCTAssertTrue(WalletStore(defaults: defaults).offchainAvailable)
    }

    private func encodedObject(_ config: WalletConfig) throws -> [String: Any] {
        let data = try JSONEncoder().encode(config)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
