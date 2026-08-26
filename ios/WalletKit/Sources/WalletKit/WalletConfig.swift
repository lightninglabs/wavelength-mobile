import Foundation

/// Bitcoin networks supported by the embedded Wavelength wallet.
public enum WalletNetwork: String, CaseIterable, Codable, Sendable {
    case signet
    case testnet
    case mainnet
    case regtest
}

/// Wire protocol used for an Ark operator or swap service endpoint.
public enum WalletTransport: String, Codable, Sendable {
    case grpc
    case rest
}

// WalletConfig is the typed mirror of the Go facade's JSON config. Optional
// properties that are nil are omitted by JSONEncoder, so the daemon's build-tag
// defaults fill in the rest. The CodingKeys match the Go json tags (snake_case).

public struct WalletConfig: Encodable, Sendable {
    public var dataDir: String
    public var network: String
    public var serverAddress: String?
    public var serverTransport: String?
    public var serverTLSCertPath: String?
    public var serverInsecure: Bool?
    public var walletType: String?
    public var walletEsploraURL: String?
    public var walletPollIntervalSeconds: Int64?
    public var swapServerAddress: String?
    public var swapServerTransport: String?
    public var swapServerTLSCertPath: String?
    public var swapServerInsecure: Bool?
    public var debugLevel: String?
    public var allowMainnet: Bool?

    enum CodingKeys: String, CodingKey {
        case dataDir = "data_dir"
        case network = "network"
        case serverAddress = "server_address"
        case serverTransport = "server_transport"
        case serverTLSCertPath = "server_tls_cert_path"
        case serverInsecure = "server_insecure"
        case walletType = "wallet_type"
        case walletEsploraURL = "wallet_esplora_url"
        case walletPollIntervalSeconds = "wallet_poll_interval_seconds"
        case swapServerAddress = "swap_server_address"
        case swapServerTransport = "swap_server_transport"
        case swapServerTLSCertPath = "swap_server_tls_cert_path"
        case swapServerInsecure = "swap_server_insecure"
        case debugLevel = "debug_level"
        case allowMainnet = "allow_mainnet"
    }

    /// A signet config for the lightweight (Esplora-backed) wallet. Empty
    /// endpoints defer to the current defaults compiled into Wavelength.
    public static func signet(
        dataDir: String,
        esploraURL: String = "",
        operatorAddress: String = "",
        swapServerAddress: String = "",
        operatorTransport: WalletTransport? = nil,
        swapTransport: WalletTransport? = nil,
        operatorTLSCertPath: String = "",
        swapTLSCertPath: String = ""
    ) -> WalletConfig {
        network(
            .signet,
            dataDir: dataDir,
            esploraURL: esploraURL,
            operatorAddress: operatorAddress,
            swapServerAddress: swapServerAddress,
            operatorTransport: operatorTransport,
            swapTransport: swapTransport,
            operatorTLSCertPath: operatorTLSCertPath,
            swapTLSCertPath: swapTLSCertPath
        )
    }

    /// A testnet3 config. Empty endpoint values deliberately defer to the
    /// defaults compiled into the Wavelength binding so a host app does not
    /// freeze infrastructure addresses at build time.
    public static func testnet(
        dataDir: String,
        esploraURL: String = "",
        operatorAddress: String = "",
        swapServerAddress: String = "",
        operatorTransport: WalletTransport? = nil,
        swapTransport: WalletTransport? = nil,
        operatorTLSCertPath: String = "",
        swapTLSCertPath: String = ""
    ) -> WalletConfig {
        network(
            .testnet,
            dataDir: dataDir,
            esploraURL: esploraURL,
            operatorAddress: operatorAddress,
            swapServerAddress: swapServerAddress,
            operatorTransport: operatorTransport,
            swapTransport: swapTransport,
            operatorTLSCertPath: operatorTLSCertPath,
            swapTLSCertPath: swapTLSCertPath
        )
    }

    /// A mainnet config. Wavelength requires the explicit `allow_mainnet`
    /// opt-in. Mainnet has no bundled public Ark or swap deployment, so wallet
    /// apps should provide operator and swap endpoints before enabling
    /// off-chain operations. On-chain sync can use the daemon's default
    /// Esplora endpoint when `esploraURL` is empty.
    public static func mainnet(
        dataDir: String,
        esploraURL: String = "",
        operatorAddress: String = "",
        swapServerAddress: String = "",
        operatorTransport: WalletTransport? = nil,
        swapTransport: WalletTransport? = nil,
        operatorTLSCertPath: String = "",
        swapTLSCertPath: String = ""
    ) -> WalletConfig {
        network(
            .mainnet,
            dataDir: dataDir,
            esploraURL: esploraURL,
            operatorAddress: operatorAddress,
            swapServerAddress: swapServerAddress,
            operatorTransport: operatorTransport,
            swapTransport: swapTransport,
            operatorTLSCertPath: operatorTLSCertPath,
            swapTLSCertPath: swapTLSCertPath
        )
    }

    /// Build a lightweight-wallet configuration for one supported network.
    public static func network(
        _ network: WalletNetwork,
        dataDir: String,
        esploraURL: String = "",
        operatorAddress: String = "",
        swapServerAddress: String = "",
        operatorTransport: WalletTransport? = nil,
        swapTransport: WalletTransport? = nil,
        operatorTLSCertPath: String = "",
        swapTLSCertPath: String = ""
    ) -> WalletConfig {
        let resolvedOperatorTransport = operatorTransport ?? .inferred(from: operatorAddress)
        let resolvedSwapTransport = swapTransport ?? .inferred(from: swapServerAddress)

        return WalletConfig(
            dataDir: dataDir,
            network: network.rawValue,
            serverAddress: operatorAddress.nilIfEmpty,
            serverTransport: resolvedOperatorTransport.rawValue,
            serverTLSCertPath: operatorTLSCertPath.nilIfEmpty,
            serverInsecure: .insecureValue(
                network: network,
                address: operatorAddress,
                transport: resolvedOperatorTransport,
                tlsCertPath: operatorTLSCertPath
            ),
            walletType: "lwwallet",
            walletEsploraURL: esploraURL.nilIfEmpty,
            walletPollIntervalSeconds: network.esploraPollIntervalSeconds,
            swapServerAddress: swapServerAddress.nilIfEmpty,
            swapServerTransport: resolvedSwapTransport.rawValue,
            swapServerTLSCertPath: swapTLSCertPath.nilIfEmpty,
            swapServerInsecure: .insecureValue(
                network: network,
                address: swapServerAddress,
                transport: resolvedSwapTransport,
                tlsCertPath: swapTLSCertPath
            ),
            debugLevel: "info",
            allowMainnet: network == .mainnet
        )
    }
}

private extension WalletNetwork {
    var esploraPollIntervalSeconds: Int64 {
        switch self {
        case .regtest: return 1
        case .signet, .testnet: return 10
        case .mainnet: return 30
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension WalletTransport {
    static func inferred(from address: String) -> WalletTransport {
        let value = address.lowercased()
        return value.hasPrefix("http://") || value.hasPrefix("https://") ? .rest : .grpc
    }
}

private extension Optional where Wrapped == Bool {
    static func insecureValue(
        network: WalletNetwork,
        address: String,
        transport: WalletTransport,
        tlsCertPath: String
    ) -> Bool? {
        guard network == .regtest, tlsCertPath.isEmpty else { return nil }
        if transport == .rest {
            return address.lowercased().hasPrefix("http://") ? true : nil
        }
        return true
    }
}
