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

/// A Lightning invoice to receive into the wallet, plus its initial entry.
public struct ReceiveResult: Decodable, Sendable {
    public let invoice: String
    public let entry: Entry

    enum CodingKeys: String, CodingKey {
        case invoice = "Invoice"
        case entry = "Entry"
    }
}

/// A fresh on-chain boarding address to deposit into, plus its initial entry.
public struct DepositResult: Decodable, Sendable {
    public let address: String
    public let entry: Entry

    enum CodingKeys: String, CodingKey {
        case address = "Address"
        case entry = "Entry"
    }
}

/// A quote for an outbound payment. Show the fee, then dispatch the quote with
/// `send(_:)` using the single-use `sendIntentID`. The fee is only known up
/// front when `feeKnown` is true.
public struct PrepareSendResult: Decodable, Sendable {
    public let sendIntentID: String
    public let amountSat: Int64
    public let expectedFeeSat: Int64
    public let feeKnown: Bool
    public let expectedTotalOutflowSat: Int64
    public let rail: String
    public let quoteStatus: String
    public let destinationSummary: String
    public let paymentHash: String
    public let warning: String

    enum CodingKeys: String, CodingKey {
        case sendIntentID = "SendIntentID"
        case amountSat = "AmountSat"
        case expectedFeeSat = "ExpectedFeeSat"
        case feeKnown = "FeeKnown"
        case expectedTotalOutflowSat = "ExpectedTotalOutflowSat"
        case rail = "Rail"
        case quoteStatus = "QuoteStatus"
        case destinationSummary = "DestinationSummary"
        case paymentHash = "PaymentHash"
        case warning = "Warning"
    }
}

/// The result of dispatching a prepared send. `actualAmountSat` is what actually
/// left the wallet, which matters for a sweep-all send.
public struct SendResult: Decodable, Sendable {
    public let entry: Entry
    public let actualAmountSat: Int64

    enum CodingKeys: String, CodingKey {
        case entry = "Entry"
        case actualAmountSat = "ActualAmountSat"
    }
}

/// Which slice of wallet state `list` returns.
public enum ListView: String, Sendable {
    case activity, vtxos, onchain
}

/// A wallet-facing view of one VTXO.
public struct WalletVTXO: Decodable, Sendable {
    public let outpoint: String
    public let amountSat: Int64
    public let status: String
    public let commitmentTxid: String

    enum CodingKeys: String, CodingKey {
        case outpoint = "Outpoint"
        case amountSat = "AmountSat"
        case status = "Status"
        case commitmentTxid = "CommitmentTxid"
    }
}

/// A wallet-facing view of one on-chain transaction.
public struct OnchainTx: Decodable, Sendable {
    public let txid: String
    public let kind: String
    public let amountSat: Int64
    public let feeSat: Int64
    public let status: String
    public let description: String

    enum CodingKeys: String, CodingKey {
        case txid = "Txid"
        case kind = "Kind"
        case amountSat = "AmountSat"
        case feeSat = "FeeSat"
        case status = "Status"
        case description = "Description"
    }
}

public struct ActivityList: Decodable, Sendable {
    public let entries: [Entry]
    public let total: Int64
    enum CodingKeys: String, CodingKey { case entries = "Entries"; case total = "Total" }
}

public struct VTXOInventory: Decodable, Sendable {
    public let vtxos: [WalletVTXO]
    public let total: Int64
    enum CodingKeys: String, CodingKey { case vtxos = "VTXOs"; case total = "Total" }
}

public struct OnchainHistory: Decodable, Sendable {
    public let txs: [OnchainTx]
    public let total: Int64
    public let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case txs = "Txs"; case total = "Total"; case hasMore = "HasMore"
    }
}

/// A unified wallet view. It is a tagged union: read the property named by
/// `view` and treat the others as nil.
public struct ListResult: Decodable, Sendable {
    public let view: String
    public let activity: ActivityList?
    public let vtxos: VTXOInventory?
    public let onchain: OnchainHistory?

    enum CodingKeys: String, CodingKey {
        case view = "View"
        case activity = "Activity"
        case vtxos = "VTXOs"
        case onchain = "Onchain"
    }
}

/// The outcome of an exit. `path` is "cooperative" or "unilateral".
public struct ExitResult: Decodable, Sendable {
    public let path: String
    public let cooperative: Bool
    public let queuedOutpoints: [String]
    public let created: Bool
    public let actorID: String

    enum CodingKeys: String, CodingKey {
        case path = "Path"
        case cooperative = "Cooperative"
        case queuedOutpoints = "QueuedOutpoints"
        case created = "Created"
        case actorID = "ActorID"
    }
}

/// The phase of an exit job. `found` is false when no job exists (not an error).
public struct ExitStatusResult: Decodable, Sendable {
    public let found: Bool
    public let status: String
    public let sweepTxid: String
    public let lastError: String

    enum CodingKeys: String, CodingKey {
        case found = "Found"
        case status = "Status"
        case sweepTxid = "SweepTxid"
        case lastError = "LastError"
    }
}
