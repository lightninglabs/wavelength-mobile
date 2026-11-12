import Foundation
import UIKit
import UserNotifications
import WalletKit

extension NotificationRelayConfiguration {
    /// Release configuration is bundled per Bitcoin network. An empty dictionary
    /// keeps enrollment disabled until the publisher provisions its relay.
    static func bundled(network: WalletNetwork, bundle: Bundle = .main) -> Self? {
        guard let all = bundle.object(forInfoDictionaryKey: "WavelengthNotificationRelays") as? [String: [String: String]],
              let value = all[network.rawValue] else { return nil }
        return Self(origin: value["origin"] ?? "", appAlias: value["appAlias"] ?? "",
                    swapIssuer: value["swapIssuer"] ?? "",
                    receiptHints: value["receiptHints"] == "true")
    }
}

/// Routing metadata is local. Neither a push's event hash nor any other remote
/// field can select a network, wallet, endpoint, payment or external URL.
struct WalletNotificationRoute: Codable, Equatable {
    let id: String
    let network: String
    let identity: String
    let relay: NotificationRelayConfiguration
    var configuration: String { relay.storageAccount }
    let source: NotificationSource
    var subscriptionID: String? = nil
    var boundGrant: String? = nil
    var presentation: String? = nil
    var boundExpiresAt: Int64? = nil

    func isBound(_ grant: NotificationRelayGrant, now: Int64 = Int64(Date().timeIntervalSince1970)) -> Bool {
        boundGrant == Self.fingerprint(grant) && (grant.previousSubscriptions ?? []).isEmpty &&
            (boundExpiresAt ?? 0) > now + 86_400
    }

    /// Stop local delivery even when the producer cannot be reached. Keep the
    /// caller's route until both sides acknowledge, so cleanup can be retried.
    static func revoke(relay: () async throws -> Void, producer: () async throws -> Void) async throws {
        var relayError: Error?
        do { try await relay() } catch { relayError = error }
        try await producer()
        if let relayError { throw relayError }
    }
    /// Finish every independent route before reporting the first failure.
    /// One unavailable producer must not leave another device route active.
    static func revokeAll(_ routes: [Self], action: (Self) async throws -> Void) async throws {
        var failure: Error?
        for route in routes {
            do { try await action(route) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    static func fingerprint(_ grant: NotificationRelayGrant) -> String {
        let offers = grant.feedOffers.sorted { $0.sourceId < $1.sourceId }.map {
            [$0.sourceId, $0.role, $0.sourcePubkey, $0.subscriberPubkey, $0.grantId,
             String($0.eventClasses), String($0.expiresAtUnix), $0.subscriberSignature].joined(separator: "\0")
        }.joined(separator: "\n")
        return grant.subscriptionId + ":" + String(grant.expiresAt) + ":" + (grant.presentation ?? "generic") + ":" +
            NotificationRelayConfiguration.digest(Data(offers.utf8))
    }

    /// A restored wallet can reconstruct its route after reinstall even when
    /// UserDefaults was removed but Keychain's prior grants survived.
    static func routeID(network: String, identity: String, relay: NotificationRelayConfiguration, source: NotificationSource) -> String {
        let fields = ["wavelength.ios.notification-route.v1", relay.storageAccount, network, identity, source.rawValue]
        return NotificationRelayConfiguration.digest(Data(fields.joined(separator: "\0").utf8))
    }

    static func parsePush(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let payload = userInfo["wavelength"] as? [String: Any],
              let version = payload["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let route = payload["route_id"] as? String,
              NotificationRelayConfiguration.identifier(route) else { return nil }
        return route
    }
}
