import Foundation

/// A local invoice admission. The source is a string so optional future
/// metadata cannot make successful invoice creation fail to decode.
public struct LightningReceiptReference: Codable, Equatable, Sendable {
    public let source: String
    public let id: String

    public init(source: String, id: String) {
        self.source = source
        self.id = id
    }

    public var isSupported: Bool {
        (source == "lightning_swap" || source == "credit_receive") &&
            !id.isEmpty && id.utf8.count <= 128
    }
}

/// A targeted local source/canonical agreement proof. Only complete is eligible
/// for amount presentation, after the host's independent consent/event checks.
public struct LightningReceipt: Decodable, Sendable {
    public let reference: LightningReceiptReference
    public let canonicalID: String
    public let state: String
    public let amountSat: Int64
    public let createdAtUnix: Int64

    enum CodingKeys: String, CodingKey {
        case reference, state
        case canonicalID = "canonical_id"
        case amountSat = "amount_sat"
        case createdAtUnix = "created_at_unix"
    }
}

/// One unique warm recovery invocation. Remote notifications never supply the
/// reference. The host enrolls it from a successful local invoice creation.
public struct ReceiptWindowRequest: Encodable, Sendable {
    public let windowID: String
    public let reference: LightningReceiptReference
    public let createdAfterUnix: Int64

    public init(windowID: String, reference: LightningReceiptReference,
                createdAfterUnix: Int64) {
        self.windowID = windowID
        self.reference = reference
        self.createdAfterUnix = createdAfterUnix
    }

    enum CodingKeys: String, CodingKey {
        case reference
        case windowID = "window_id"
        case createdAfterUnix = "created_after_unix"
    }
}

/// A bounded local attempt. No flag proves global catchup or safe suspension.
public struct ReceiptWindowResult: Decodable, Sendable {
    public let receipts: [LightningReceipt]
    public let batches: UInt32
    public let needsForeground: Bool
    public let interrupted: Bool
    public let budgetExhausted: Bool
    public let maintenanceChecked: UInt32?
    public let maintenanceDeferred: Bool?
    public let maintenanceMore: Bool?

    enum CodingKeys: String, CodingKey {
        case receipts, batches, interrupted
        case needsForeground = "needs_foreground"
        case budgetExhausted = "budget_exhausted"
        case maintenanceChecked = "maintenance_checked"
        case maintenanceDeferred = "maintenance_deferred"
        case maintenanceMore = "maintenance_more"
    }
}
