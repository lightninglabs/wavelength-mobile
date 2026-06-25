import Foundation

// The wrapper decodes the JSON the Go facade emits. The Go DTOs carry no json
// tags, so their wire keys are the Go field names (PascalCase); each model maps
// them with CodingKeys and exposes idiomatic Swift properties. Unknown keys are
// ignored by Codable, so a model may cover a subset of a verb's fields.

/// Wallet lifecycle state reported by the daemon.
public enum WalletState: Int, Sendable {
    case unspecified = 0
    case none = 1
    case locked = 2
    case ready = 3
    case syncing = 4

    init(code: Int) { self = WalletState(rawValue: code) ?? .unspecified }
}

/// Daemon readiness snapshot (`getInfo`).
public struct Info: Decodable, Sendable {
    public let version: String
    public let commit: String
    public let network: String
    public let blockHeight: Int64
    public let serverConnected: Bool
    public let walletType: String
    public let walletStateCode: Int
    public let identityPubKey: String

    public var walletState: WalletState { WalletState(code: walletStateCode) }
    public var walletReady: Bool { walletState == .ready }

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case commit = "Commit"
        case network = "Network"
        case blockHeight = "BlockHeight"
        case serverConnected = "ServerConnected"
        case walletType = "WalletType"
        case walletStateCode = "WalletState"
        case identityPubKey = "IdentityPubKey"
    }
}

/// Wallet balance summary (`balance`).
public struct Balance: Decodable, Sendable {
    public let confirmedSat: Int64
    public let pendingInSat: Int64
    public let pendingOutSat: Int64

    enum CodingKeys: String, CodingKey {
        case confirmedSat = "ConfirmedSat"
        case pendingInSat = "PendingInSat"
        case pendingOutSat = "PendingOutSat"
    }
}

/// Wallet readiness + pending activity (`status`).
public struct Status: Decodable, Sendable {
    public let ready: Bool
    public let unlocked: Bool
    public let network: String
    public let balance: Balance
    public let pendingCount: Int64

    enum CodingKeys: String, CodingKey {
        case ready = "Ready"
        case unlocked = "Unlocked"
        case network = "Network"
        case balance = "Balance"
        case pendingCount = "PendingCount"
    }
}

/// Result of creating or importing a wallet (`createWallet`).
public struct CreateWalletResult: Decodable, Sendable {
    public let mnemonic: [String]
    public let identityPubKey: String
    public let recoveryRan: Bool

    enum CodingKeys: String, CodingKey {
        case mnemonic = "Mnemonic"
        case identityPubKey = "IdentityPubKey"
        case recoveryRan = "RecoveryRan"
    }
}

/// Result of unlocking a wallet (`unlockWallet`).
public struct UnlockWalletResult: Decodable, Sendable {
    public let identityPubKey: String

    enum CodingKeys: String, CodingKey {
        case identityPubKey = "IdentityPubKey"
    }
}

/// One activity entry from the wallet stream (`subscribe`).
public struct Entry: Decodable, Sendable {
    public let id: String
    public let kind: String
    public let status: String
    public let amountSat: Int64
    public let feeSat: Int64
    public let counterparty: String
    public let note: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case kind = "Kind"
        case status = "Status"
        case amountSat = "AmountSat"
        case feeSat = "FeeSat"
        case counterparty = "Counterparty"
        case note = "Note"
    }
}
