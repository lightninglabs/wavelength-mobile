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
                    producerAlias: value["producerAlias"] ?? "", swapIssuer: value["swapIssuer"] ?? "",
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
    var boundGrant: String? = nil
    var presentation: String? = nil
    var boundExpiresAt: Int64? = nil

    func isBound(_ grant: NotificationRelayGrant) -> Bool {
        boundGrant == Self.fingerprint(grant) && (grant.previousSubscriptions ?? []).isEmpty
    }
    static func fingerprint(_ grant: NotificationRelayGrant) -> String {
        grant.subscriptionId + ":" + String(grant.expiresAt) + ":" + (grant.presentation ?? "generic") + ":" +
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
    private let receiptLedger = ReceiptNotificationLedger()
    private var activeReceiptWindow: String?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var enabled: Bool {
        guard let store else { return false }
        return defaults.bool(forKey: preference(store.network.rawValue))
    }
    var available: Bool { store?.notificationConfiguration != nil }
    var amountsAvailable: Bool { store?.notificationConfiguration?.receiptHints == true }
    var amountsEnabled: Bool {
        guard let store else { return false }
        return defaults.bool(forKey: "notifications.amounts." + store.network.rawValue)
    }

    func setAmountsEnabled(_ requested: Bool) {
        guard !working, let store, !requested || (enabled && amountsAvailable) else { return }
        let network = store.network.rawValue
        do {
            // Every opt-in starts a fresh epoch. Never enroll old invoices.
            try receiptLedger.revoke(network: network)
            if requested {
                try receiptLedger.ensureConsent(network: network, now: Int64(Date().timeIntervalSince1970))
            }
            defaults.set(requested, forKey: "notifications.amounts." + network)
            objectWillChange.send()
            reconcile()
        } catch { status = "Couldn’t save notification preferences. Try again after unlocking this device." }
    }

    func enteredBackground() {
        WalletBackgroundMaintenance.schedule()
        guard let store else { return }
        Task { await store.setReceiptBackgroundMode(enabled: true) }
    }

    /// Connect lifetime ownership at app construction, including background launch.
    /// This does not start the wallet or read any unlock credential.
    func retainWarmStore(_ store: WalletStore) { self.store = store }

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
            try? receiptLedger.revoke(network: network)
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
                    let wantsHints = source == .swapServer && amountsEnabled && configuration.receiptHints == true
                    if wantsHints {
                        try receiptLedger.ensureConsent(network: network, now: Int64(Date().timeIntervalSince1970))
                    }
                    let grant = try await client.subscribe(token: token, routeId: route.id,
                                                           alerts: source == .swapServer, receiptHints: wantsHints)
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
                    bound.presentation = grant.presentation ?? "generic"
                    bound.boundExpiresAt = grant.expiresAt
                    try updateRoute(bound)
                }
                status = previousExpiry == nil ? (amountsEnabled && amountsAvailable ?
                    "Notifications are on. New invoices can show verified received amounts." :
                    "Notifications are on. Payment alerts show no amounts.") :
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

    /// Foreground delivery refreshes the visible activity. Background work uses
    /// the separately retained, bounded native window below.
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
        WalletBackgroundMaintenance.register()
        WalletBackgroundMaintenance.schedule()
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
            let windowID = UUID().uuidString
            let lease = ReceiptFetchLease(completion: completionHandler)
            let expire: () -> Void = {
                guard !lease.finished else { return }
                lease.expire()
                Task { await WalletNotifications.shared.cancelReceiptRecovery(windowID) }
            }
            lease.backgroundTask = application.beginBackgroundTask(withName: "Invoice receipt", expirationHandler: {
                Task { @MainActor in expire() }
            })
            let deadline = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if !Task.isCancelled { expire() }
            }
            let changed = await WalletNotifications.shared.received(userInfo, windowID: windowID, lease: lease)
            deadline.cancel()
            lease.finish(changed ? .newData : .noData)
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.trigger is UNPushNotificationTrigger {
            Task { @MainActor in WalletNotifications.shared.received(notification.request.content.userInfo) }
        }
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


struct ReceiptCreationContext {
    let route: WalletNotificationRoute
    let consent: ReceiptConsent
    let generation: Int
}

extension WalletNotifications {
    func receiptCreationContext() -> ReceiptCreationContext? {
        guard enabled, amountsEnabled, amountsAvailable, let store,
              let identity = store.notificationIdentity,
              let configuration = store.notificationConfiguration,
              let route = routes().first(where: {
                  $0.source == .swapServer && $0.network == store.network.rawValue &&
                  $0.identity == identity && $0.configuration == configuration.storageAccount &&
                  $0.presentation == "receipt_hint" && $0.boundGrant != nil &&
                  ($0.boundExpiresAt ?? 0) > Int64(Date().timeIntervalSince1970)
              }), let consent = try? receiptLedger.consent(network: route.network) else { return nil }
        return ReceiptCreationContext(route: route, consent: consent, generation: store.notificationGeneration)
    }

    func enrollCreatedReceive(_ result: ReceiveResult, context: ReceiptCreationContext?) {
        guard let context, let current = receiptCreationContext(),
              current.route.id == context.route.id, current.consent == context.consent,
              current.generation == context.generation,
              let reference = result.receiptReference, reference.isSupported,
              result.entry.amountSat > 0 else { return }
        let requestHash = result.entry.request?.paymentHash ?? ""
        let progressHash = result.entry.progress?.paymentHash ?? ""
        guard requestHash.isEmpty || progressHash.isEmpty || requestHash == progressHash,
              let eventHash = ReceiptEventIdentity.relayHash(owner: context.route.identity,
                  paymentHash: requestHash.isEmpty ? progressHash : requestHash) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        // Optional enrollment storage can fail without failing invoice creation.
        try? receiptLedger.enroll(ReceiptEnrollment(
            routeID: context.route.id, network: context.route.network,
            identity: context.route.identity, configuration: context.route.configuration,
            consent: context.consent, reference: reference, eventHash: eventHash,
            amountSat: result.entry.amountSat, enrolledAt: now
        ), now: now)
    }

    func cancelReceiptRecovery(_ windowID: String) async {
        guard activeReceiptWindow == windowID else { return }
        await store?.cancelReceiptWindow(windowID)
    }

    /// Only the relay's payment marker can authorize a local fallback. A wake
    /// or already-visible remote alert never creates another local banner.
    func received(_ userInfo: [AnyHashable: Any], windowID: String,
                  lease: ReceiptFetchLease) async -> Bool {
        received(userInfo)
        guard !lease.expired else { return false }
        guard let hint = ReceiptPaymentHint(userInfo: userInfo) else {
            guard let id = WalletNotificationRoute.parsePush(userInfo), validWakeRoute(id) != nil else { return false }
            return await runMaintenance(windowID: windowID, lease: lease)
        }
        guard let store, let route = validPaymentRoute(hint.routeID) else { return false }
        let id = hint.routeID
        let eventHash = hint.eventHash
        let generation = store.notificationGeneration
        let now = Int64(Date().timeIntervalSince1970)
        var enrollment: ReceiptEnrollment?
        do { enrollment = try receiptLedger.enrolled(routeID: id, eventHash: eventHash, now: now) }
        catch { return false }
        var result: ReceiptWindowResult?
        if amountsEnabled, amountsAvailable, route.presentation == "receipt_hint",
           let enrolled = enrollment, enrolled.identity == store.notificationIdentity,
           enrolled.configuration == route.configuration, activeReceiptWindow == nil {
            activeReceiptWindow = windowID
            await store.setReceiptBackgroundMode(enabled: true)
            result = try? await store.runReceiptWindow(ReceiptWindowRequest(
                windowID: windowID, reference: enrolled.reference,
                createdAfterUnix: enrolled.consent.createdAfterUnix
            ), identity: enrolled.identity)
            if activeReceiptWindow == windowID { activeReceiptWindow = nil }
        } else {
            _ = await runMaintenance(windowID: windowID, lease: lease)
        }
        guard !lease.expired, store.notificationGeneration == generation,
              validPaymentRoute(id) != nil else { return false }
        // A lock, consent change or account switch during await removes amount
        // authority. Generic activity still requires current route consent.
        if !amountsEnabled || !amountsAvailable ||
            enrollment?.identity != store.notificationIdentity ||
            (try? receiptLedger.consent(network: route.network)) != enrollment?.consent {
            enrollment = nil
            result = nil
        }
        let body = ReceiptNotificationPresentation.body(enrollment: enrollment, result: result)
        do {
            guard try receiptLedger.claim(routeID: id, eventHash: eventHash,
                                          now: Int64(Date().timeIntervalSince1970)) else { return false }
            let content = UNMutableNotificationContent()
            content.title = "Wavelength"
            content.body = body
            content.sound = .default
            content.userInfo = ["wavelength": ["version": 1, "route_id": id, "event_id": eventHash]]
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "receipt." + NotificationRelayConfiguration.digest(Data((id + ":" + eventHash).utf8)),
                content: content, trigger: nil
            ))
            return result?.receipts.contains(where: { $0.state == "complete" }) == true
        } catch { return false }
    }

    /// A scheduled opportunity needs no notification consent: it advances only
    /// existing warm wallet work and never creates a local payment alert.
    func runMaintenance(windowID: String, lease: ReceiptFetchLease) async -> Bool {
        guard !lease.expired, activeReceiptWindow == nil, let store else { return false }
        activeReceiptWindow = windowID
        defer { if activeReceiptWindow == windowID { activeReceiptWindow = nil } }
        // Cancellation can arrive during this pause; the unique-ID fence still
        // rejects the native invocation before admission.
        await store.setReceiptBackgroundMode(enabled: true)
        guard !lease.expired else { return false }
        let result = try? await store.runMaintenanceWindow(windowID)
        return (result?.batches ?? 0) > 0 || (result?.maintenanceChecked ?? 0) > 0
    }

    private func validWakeRoute(_ id: String) -> WalletNotificationRoute? {
        guard let store, enabled, let configuration = store.notificationConfiguration else { return nil }
        return routes().first {
            $0.id == id && $0.network == store.network.rawValue &&
            $0.configuration == configuration.storageAccount && $0.boundGrant != nil &&
            ($0.boundExpiresAt ?? 0) > Int64(Date().timeIntervalSince1970) &&
            $0.identity == store.notificationKnownIdentity
        }
    }

    private func validPaymentRoute(_ id: String) -> WalletNotificationRoute? {
        guard let store, defaults.bool(forKey: preference(store.network.rawValue)),
              let configuration = store.notificationConfiguration else { return nil }
        return routes().first {
            $0.id == id && $0.source == .swapServer &&
            $0.network == store.network.rawValue && $0.configuration == configuration.storageAccount &&
            (store.notificationKnownIdentity == nil || $0.identity == store.notificationKnownIdentity)
        }
    }
}
