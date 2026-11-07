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
                    producerAlias: value["producerAlias"] ?? "", swapIssuer: value["swapIssuer"] ?? "")
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
    var boundGrant: String? = nil

    func isBound(_ grant: NotificationRelayGrant) -> Bool {
        boundGrant == Self.fingerprint(grant) && (grant.previousSubscriptions ?? []).isEmpty
    }
    static func fingerprint(_ grant: NotificationRelayGrant) -> String {
        grant.subscriptionId + ":" + String(grant.expiresAt) + ":" +
            NotificationRelayConfiguration.digest(Data((grant.wakeCapability + "\0" + (grant.alertCapability ?? "")).utf8))
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

@MainActor
final class WalletNotifications: ObservableObject {
    static let shared = WalletNotifications()
    @Published private(set) var status = "Notifications are off."
    @Published private(set) var working = false
    @Published var showsActivity = false
    private weak var store: WalletStore?
    private let defaults: UserDefaults
    private var token: String?
    private var clients: [String: NotificationRelayClient] = [:]
    private var reconcileAgain = false
    private var pendingTap: WalletNotificationRoute?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var enabled: Bool {
        guard let store else { return false }
        return defaults.bool(forKey: preference(store.network.rawValue))
    }
    var available: Bool { store?.notificationConfiguration != nil }

    func attach(_ store: WalletStore) {
        self.store = store
        if enabled { UIApplication.shared.registerForRemoteNotifications() }
        reconcile()
    }

    func registered(token: Data) {
        self.token = token.map { String(format: "%02x", $0) }.joined()
        reconcile()
    }

    func registrationFailed() { status = "Couldn’t register this device. Try again in Settings." }

    func setEnabled(_ requested: Bool) async {
        guard !working, let store else { return }
        let network = store.network.rawValue
        if requested {
            guard available else { status = "Notifications are not configured for this connection."; return }
            do {
                guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else {
                    status = "Allow notifications in iOS Settings, then try again."
                    return
                }
                // Consent applies to the selected wallet network, even if the
                // system permission sheet outlives a network switch.
                defaults.set(true, forKey: preference(network))
                UIApplication.shared.registerForRemoteNotifications()
            } catch { status = "Couldn’t request notification permission." }
        } else {
            // Keep route metadata until the relay acknowledges revocation.
            defaults.set(false, forKey: preference(network))
        }
        objectWillChange.send()
        reconcile()
    }

    func reconcile() {
        openPendingTap()
        if working { reconcileAgain = true; return }
        guard UIApplication.shared.applicationState == .active, let store else { return }
        let configuration = store.notificationConfiguration
        let network = store.network.rawValue
        let desired = defaults.bool(forKey: preference(network))
        working = true
        Task {
            defer {
                working = false
                if reconcileAgain {
                    reconcileAgain = false
                    reconcile()
                }
            }
            do {
                // Revoke using the original bundled origin even after an
                // endpoint or publisher configuration change. A signed 401 is
                // not proof that a route has been revoked.
                let identity = store.notificationIdentity
                let obsolete = routes().filter {
                    !defaults.bool(forKey: preference($0.network)) ||
                        ($0.network == network &&
                            ($0.configuration != configuration?.storageAccount ||
                                (identity != nil && $0.identity != identity)))
                }
                var previousExpiry: Int64?
                for route in obsolete {
                    do {
                        try await relay(route.relay).revoke(routeId: route.id)
                        removeRoute(route.id)
                    } catch NotificationRelayError.previousInstallationExpires(let expiry) where desired {
                        // A destroyed key cannot revoke another installation.
                        // Keep its metadata until expiry while setting up the
                        // current wallet with a new attested key.
                        previousExpiry = max(previousExpiry ?? 0, expiry)
                    }
                }
                if !desired { status = "Notifications are off."; return }
                guard let configuration else {
                    status = "Notifications are not configured for this connection."
                    return
                }
                let client = relay(configuration)
                guard let token else {
                    UIApplication.shared.registerForRemoteNotifications()
                    status = "Waiting for device registration."
                    return
                }
                guard let identity = store.notificationIdentity else {
                    status = "Unlock your wallet to finish notification setup."
                    return
                }
                for source in [NotificationSource.arkOperator, .swapServer] {
                    // A network switch or consent change aborts this pass. The
                    // native registration call separately pins its generation.
                    guard store.network.rawValue == network,
                          defaults.bool(forKey: preference(network)),
                          store.notificationIdentity == identity else { return }
                    let route = try route(network: network, identity: identity, configuration: configuration, source: source)
                    let grant = try await client.subscribe(token: token, routeId: route.id, alerts: source == .swapServer)
                    guard defaults.bool(forKey: preference(network)) else {
                        try await client.revoke(routeId: route.id)
                        removeRoute(route.id)
                        return
                    }
                    if route.isBound(grant) { continue }
                    // Replacement of an Apple-destroyed installation key does
                    // not revoke its old grants. Remove the old wallet-owned
                    // producer routes before activating the replacement.
                    for previous in grant.previousSubscriptions ?? [] where previous.expiresAt > Int64(Date().timeIntervalSince1970) {
                        try await store.removeNotification(previous.id, source: source, network: network, identity: identity)
                    }
                    try await client.acknowledgeReplacedSubscriptions(routeId: route.id)
                    try await store.bindNotification(grant, source: source, configuration: configuration,
                                                     network: network, identity: identity)
                    var bound = route
                    bound.boundGrant = WalletNotificationRoute.fingerprint(grant)
                    try updateRoute(bound)
                }
                status = previousExpiry == nil ? "Notifications are on. Payment alerts show no amounts." :
                    "Notifications are on. Previous installation grants are waiting to expire."
            } catch NotificationRelayError.previousInstallationExpires(let expiry) {
                status = "Previous installation keys were removed by iOS. Turning off completes by " +
                    Date(timeIntervalSince1970: TimeInterval(expiry)).formatted(date: .abbreviated, time: .omitted) + "."
            } catch is CancellationError {
                status = "Notification setup will resume when you open the wallet."
            } catch {
                // Do not render provider bodies or proof errors, which can carry
                // private registration material. Preserve grants for retry.
                status = desired ? "Notification setup is pending. Open the wallet to retry." :
                    "Turning off is pending. Open the wallet to retry."
            }
        }
    }

    func tapped(_ userInfo: [AnyHashable: Any]) {
        guard let id = WalletNotificationRoute.parsePush(userInfo),
              let route = routes().first(where: { $0.id == id }) else { return }
        pendingTap = route
        openPendingTap()
    }

    /// Background delivery currently leaves the daemon untouched. An alert can
    /// open a locked or terminated app without claiming that receive completed.
    func received(_ userInfo: [AnyHashable: Any]) {
        guard let id = WalletNotificationRoute.parsePush(userInfo),
              let store, let route = routes().first(where: { $0.id == id }),
              route.network == store.network.rawValue,
              route.identity == store.notificationIdentity,
              UIApplication.shared.applicationState == .active else { return }
        Task { await store.refresh() }
    }

    private func openPendingTap() {
        guard let route = pendingTap, let store,
              UIApplication.shared.applicationState == .active else { return }
        guard route.network == store.network.rawValue else {
            status = "Open the \(route.network.capitalized) wallet to view this notification."
            return
        }
        guard route.identity == store.notificationIdentity else { return }
        pendingTap = nil
        Task {
            await store.refresh()
            guard route.network == store.network.rawValue,
                  route.identity == store.notificationIdentity else { return }
            showsActivity = true
        }
    }

    private func relay(_ configuration: NotificationRelayConfiguration) -> NotificationRelayClient {
        if let existing = clients[configuration.storageAccount] { return existing }
        let client = NotificationRelayClient(configuration: configuration)
        clients[configuration.storageAccount] = client
        return client
    }

    private func preference(_ network: String) -> String { "notifications.enabled." + network }
    private func routes() -> [WalletNotificationRoute] {
        guard let data = defaults.data(forKey: "notifications.routes") else { return [] }
        return (try? JSONDecoder().decode([WalletNotificationRoute].self, from: data)) ?? []
    }
    private func route(network: String, identity: String, configuration: NotificationRelayConfiguration,
                       source: NotificationSource) throws -> WalletNotificationRoute {
        var saved = routes()
        if let route = saved.first(where: {
            $0.network == network && $0.identity == identity &&
                $0.configuration == configuration.storageAccount && $0.source == source
        }) { return route }
        let route = WalletNotificationRoute(id: WalletNotificationRoute.routeID(network: network, identity: identity, relay: configuration, source: source), network: network,
                                           identity: identity, relay: configuration, source: source)
        saved.append(route)
        defaults.set(try JSONEncoder().encode(saved), forKey: "notifications.routes")
        return route
    }
    private func updateRoute(_ route: WalletNotificationRoute) throws {
        let saved = routes().map { $0.id == route.id ? route : $0 }
        defaults.set(try JSONEncoder().encode(saved), forKey: "notifications.routes")
    }
    private func removeRoute(_ id: String) {
        if let data = try? JSONEncoder().encode(routes().filter { $0.id != id }) {
            defaults.set(data, forKey: "notifications.routes")
        }
    }
}

final class WalletNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in WalletNotifications.shared.registered(token: deviceToken) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in WalletNotifications.shared.registrationFailed() }
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            WalletNotifications.shared.received(userInfo)
            completionHandler(.noData)
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in WalletNotifications.shared.received(notification.request.content.userInfo) }
        completionHandler([.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            WalletNotifications.shared.tapped(response.notification.request.content.userInfo)
            completionHandler()
        }
    }
}
