import Foundation
import LocalAuthentication
import Security
import UIKit

/// Authenticates foreground interaction. The protected credential functions
/// remain only for reading and migrating wallets created by older versions.
enum WalletAuthentication {
    private static let service = "engineering.lightning.wavelength.wallet.biometric"

    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static var name: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        default: return "Device passcode"
        }
    }

    /// The device passcode is the system fallback when biometrics are unavailable.
    static func authenticate() async throws {
        let context = LAContext()
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                               localizedReason: "Unlock Wavelength") else {
            throw KeychainError(status: errSecAuthFailed)
        }
    }

    /// LocalAuthentication may complete while its system sheet is still
    /// dismissing. Wait for that inactive-to-active transition, but
    /// never carry authentication through an actual background transition.
    @MainActor static func waitForForeground() async throws {
        try await waitForForeground(applicationState: { UIApplication.shared.applicationState })
    }

    @MainActor static func waitForForeground(
        applicationState: () -> UIApplication.State
    ) async throws {
        while true {
            try Task.checkCancellation()
            switch applicationState() {
            case .active: return
            case .background: throw LAError(.systemCancel)
            case .inactive: try await Task.sleep(nanoseconds: 20_000_000)
            @unknown default: throw LAError(.systemCancel)
            }
        }
    }

    /// Publish and verify the background-readable copy before removing the
    /// legacy item. A failed write/read leaves the authenticated source intact.
    static func migrate(_ secret: Data, account: String) throws {
        try KeychainStore.save(secret, account: account)
        guard try KeychainStore.read(account: account) == secret else {
            throw KeychainError(status: errSecDecode)
        }
        try delete(account: account)
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
