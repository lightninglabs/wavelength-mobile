import Foundation

/// A locally configured notification producer. Push payloads cannot select a
/// server address or change the trusted issuer of either source.
public enum NotificationSource: String, Codable, Sendable {
    case arkOperator = "operator"
    case swapServer = "swap_server"
}

/// A relay-issued route, bound to this wallet by the native signing bridge.
/// Bearer capabilities are private credentials. Persist them in secure storage
/// and do not put this request in diagnostics or notification payloads.
public struct NotificationSubscription: Encodable, Sendable {
    public let source: NotificationSource
    public let subscriptionID: String
    public let relayID: String?
    public let wakeCapability: String?
    public let alertCapability: String?
    public let expiresAtUnix: Int64?
    public let remove: Bool

    private init(
        source: NotificationSource, subscriptionID: String,
        relayID: String?, wakeCapability: String?, alertCapability: String?,
        expiresAtUnix: Int64?, remove: Bool
    ) {
        self.source = source
        self.subscriptionID = subscriptionID
        self.relayID = relayID
        self.wakeCapability = wakeCapability
        self.alertCapability = alertCapability
        self.expiresAtUnix = expiresAtUnix
        self.remove = remove
    }

    /// Register or renew a route. The relay alias must match a producer's local
    /// allowlist, and the expiry cannot exceed the relay-issued grant expiry.
    public static func register(
        source: NotificationSource, subscriptionID: String, relayID: String,
        wakeCapability: String, alertCapability: String? = nil,
        expiresAtUnix: Int64
    ) -> Self {
        Self(
            source: source, subscriptionID: subscriptionID, relayID: relayID,
            wakeCapability: wakeCapability, alertCapability: alertCapability,
            expiresAtUnix: expiresAtUnix, remove: false
        )
    }

    /// Remove this wallet's route without retaining or sending its capabilities.
    public static func remove(source: NotificationSource, subscriptionID: String) -> Self {
        Self(
            source: source, subscriptionID: subscriptionID, relayID: nil,
            wakeCapability: nil, alertCapability: nil, expiresAtUnix: nil, remove: true
        )
    }

    enum CodingKeys: String, CodingKey {
        case source, remove
        case subscriptionID = "subscription_id", relayID = "relay_id"
        case wakeCapability = "wake_capability", alertCapability = "alert_capability"
        case expiresAtUnix = "expires_at_unix"
    }
}

/// Confirms a producer registration without returning bearer capabilities.
public struct NotificationSubscriptionResult: Decodable, Sendable {
    public let subscriptionID: String
    public let expiresAtUnix: Int64

    enum CodingKeys: String, CodingKey {
        case subscriptionID = "subscription_id", expiresAtUnix = "expires_at_unix"
    }
}
