import Foundation
import Security
import SwiftUI
import WalletKit

enum WalletPhase: Equatable {
    case idle
    case starting
    case needsSetup
    case needsUnlock
    case syncing
    case ready
    case failed(String)

    var isWalletAvailable: Bool {
        self == .syncing || self == .ready
    }
}

extension WalletNetwork {
    static var selectableNetworks: [WalletNetwork] {
        #if DEBUG
        return allCases
        #else
        return [.signet, .testnet, .mainnet]
        #endif
    }

    var title: String {
        switch self {
        case .signet: return "Signet"
        case .testnet: return "Testnet"
        case .mainnet: return "Mainnet"
        case .regtest: return "Regtest"
        }
    }

    var subtitle: String {
        switch self {
        case .signet: return "Safe development coins"
        case .testnet: return "Public Bitcoin test network"
        case .mainnet: return "Real bitcoin"
        case .regtest: return "Local integration stack"
        }
    }

    var color: Color {
        switch self {
        case .signet: return .purple
        case .testnet: return .blue
        case .mainnet: return .orange
        case .regtest: return .pink
        }
    }

    func transactionURL(txid: String) -> URL? {
        let path: String
        switch self {
        case .signet: path = "https://mempool.space/signet/tx/"
        case .testnet: path = "https://mempool.space/testnet/tx/"
        case .mainnet: path = "https://mempool.space/tx/"
        case .regtest: return nil
        }
        return URL(string: path + txid)
    }

    func addressURL(address: String) -> URL? {
        let path: String
        switch self {
        case .signet: path = "https://mempool.space/signet/address/"
        case .testnet: path = "https://mempool.space/testnet/address/"
        case .mainnet: path = "https://mempool.space/address/"
        case .regtest: return nil
        }
        return URL(string: path + address)
    }
}

enum WalletFormatting {
    static let satoshis: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func sats(_ value: Int64, signed: Bool = false) -> String {
        let magnitude = satoshis.string(from: NSNumber(value: abs(value))) ?? "\(abs(value))"
        if signed {
            return (value < 0 ? "−" : "+") + magnitude + " sats"
        }
        return magnitude + " sats"
    }

    static func date(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func shortened(_ value: String, head: Int = 10, tail: Int = 8) -> String {
        guard value.count > head + tail + 1 else { return value }
        return "\(value.prefix(head))…\(value.suffix(tail))"
    }
}

enum KeychainStore {
    private static let service = "engineering.lightning.wavelength.wallet"

    static func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    static func save(_ data: Data, account: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var item = key
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    static func randomSecret(byteCount: Int = 32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return Data(bytes)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

extension Error {
    var walletMessage: String {
        if let localized = self as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return (self as NSError).localizedDescription
    }
}
