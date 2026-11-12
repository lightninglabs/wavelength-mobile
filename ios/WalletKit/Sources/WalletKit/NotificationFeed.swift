import Foundation

/// Observation authority for a publisher key at an already configured source.
/// Neither the offer nor a push can select an RPC endpoint or wallet signer.
public struct NotificationFeedGrant: Encodable, Sendable {
    public let source: NotificationSource
    public let grantID: String
    public let subscriberPubkey: String?
    public let subscriberSignature: String?
    public let eventClasses: UInt32?
    public let expiresAtUnix: Int64?
    public let remove: Bool

    public static func register(source: NotificationSource, grantID: String,
                                subscriberPubkey: String, subscriberSignature: String,
                                eventClasses: UInt32, expiresAtUnix: Int64) -> Self {
        Self(source: source, grantID: grantID, subscriberPubkey: subscriberPubkey,
             subscriberSignature: subscriberSignature, eventClasses: eventClasses,
             expiresAtUnix: expiresAtUnix, remove: false)
    }

    public static func remove(source: NotificationSource, grantID: String) -> Self {
        Self(source: source, grantID: grantID, subscriberPubkey: nil,
             subscriberSignature: nil, eventClasses: nil, expiresAtUnix: nil, remove: true)
    }

    enum CodingKeys: String, CodingKey {
        case source, remove
        case grantID = "grant_id", subscriberPubkey = "subscriber_pubkey"
        case subscriberSignature = "subscriber_signature", eventClasses = "event_classes"
        case expiresAtUnix = "expires_at_unix"
    }
}

/// Correlation returned by the producer. It grants no mailbox-read authority.
public struct NotificationFeedGrantResult: Decodable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let grantID: String
    public let feedToken: String
    public let expiresAtUnix: Int64
    public var description: String { "NotificationFeedGrantResult(grantID: \(grantID))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["grantID": grantID]) }

    enum CodingKeys: String, CodingKey {
        case grantID = "grant_id", feedToken = "feed_token", expiresAtUnix = "expires_at_unix"
    }
}

/// Intake observations only. Domain work and outgoing effects may remain.
public struct IngressStepResult: Decodable, Sendable {
    public let batches: UInt32
    public let mailboxEmpty: Bool
    public let needsForeground: Bool
    enum CodingKeys: String, CodingKey {
        case batches, mailboxEmpty = "mailbox_empty", needsForeground = "needs_foreground"
    }
}
