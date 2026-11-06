import Foundation
import LocalAuthentication
import Security

/// Protects the actual wallet credential in Keychain. Authentication is enforced
/// by Keychain access control, not by a separate UI-only Face ID success flag.
enum WalletAuthentication {
    private static let service = "engineering.lightning.wavelength.wallet.biometric"

    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static var name: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "Face ID"
    }

    static func contains(account: String) -> Bool {
        var query = key(account)
        query[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func save(_ data: Data, account: String) throws {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else {
            throw error?.takeRetainedValue() ?? KeychainError(status: errSecParam) as Error
        }
        var item = key(account)
        item[kSecAttrAccessControl as String] = control
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func read(account: String) throws -> Data {
        let context = LAContext()
        return try read(account: account, context: context)
    }

    /// One explicit settings action can authenticate several wallet entries
    /// with the same context, without sharing their credential values.
    static func read(accounts: [String]) throws -> [(String, Data)] {
        let context = LAContext()
        return try accounts.map { ($0, try read(account: $0, context: context)) }
    }

    private static func read(account: String, context: LAContext) throws -> Data {
        context.localizedReason = "Unlock Wavelength"
        var query = key(account)
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(key(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private static func key(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
