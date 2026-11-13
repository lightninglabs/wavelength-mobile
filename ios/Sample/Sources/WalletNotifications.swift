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
    static func revoke<Result>(relay: () async throws -> Void, producer: () async throws -> Result) async throws -> Result {
        var relayError: Error?
        do { try await relay() } catch { relayError = error }
        let result = try await producer()
        if let relayError { throw relayError }
        return result
    }
    /// A relay acknowledgement cannot stand in for removing a bound source
    /// grant. False retains metadata until the matching wallet can finish.
    func revoke(currentNetwork: String, currentIdentity: String?,
                relay: () async throws -> Void,
                producer: (String) async throws -> Void) async throws -> Bool {
        try await Self.revoke(relay: relay) {
            guard let id = subscriptionID else { return true }
            guard network == currentNetwork, identity == currentIdentity else { return false }
            try await producer(id)
            return true
        }
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

@MainActor
final class WalletNotifications: ObservableObject {
    static let shared = WalletNotifications()
    @Published private(set) var status = "Notifications are off."
    @Published private(set) var working = false
    @Published private(set) var notice: String?
    @Published var showsActivity = false
    private weak var store: WalletStore?
    private let defaults: UserDefaults
    private var token: String?
    private var clients: [String: NotificationRelayClient] = [:]
    private var reconcileAgain = false
    private var pendingTap: WalletNotificationRoute?
    private let receiptLedger: ReceiptNotificationLedger
    private var activeReceiptWindow: String?
    private let authorize: @MainActor () async throws -> Bool
    private let configurationForStore: @MainActor (WalletStore) -> NotificationRelayConfiguration?
    private let registerDevice: @MainActor () -> Void

    init(defaults: UserDefaults = .standard, receiptLedger: ReceiptNotificationLedger? = nil,
         configuration: @escaping @MainActor (WalletStore) -> NotificationRelayConfiguration? = { $0.notificationConfiguration },
         authorize: @escaping @MainActor () async throws -> Bool = {
             try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
         }, registerDevice: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() }) {
        self.defaults = defaults
        self.receiptLedger = receiptLedger ?? ReceiptNotificationLedger()
        self.configurationForStore = configuration
        self.authorize = authorize
        self.registerDevice = registerDevice
    }

    var diagnosticNetwork: String? { store?.network.rawValue }

    var enabled: Bool {
        guard let store else { return false }
        return defaults.bool(forKey: preference(store.network.rawValue))
    }
    var available: Bool { guard let store else { return false }; return configurationForStore(store) != nil }
    var amountsAvailable: Bool { guard let store else { return false }; return configurationForStore(store)?.receiptHints == true }
    var settingsStatus: String {
        if let notice { return notice }
        return !available ? unavailableMessage : status
    }

    func retrySetup() { notice = nil; reconcile() }
    private var unavailableMessage: String {
        guard let store else { return "Open your wallet to set up notifications." }
        if !store.operatorAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !store.swapServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Notifications need the default operator and swap server. Check Connection settings."
        }
        return "Notifications aren’t configured for \(store.network.rawValue.capitalized) in this build."
    }

    // This consent explicitly covers amounts while the app is locked. Old
    // consent used different wording and must not silently opt users in.
    var amountsEnabled: Bool {
        guard let store else { return false }
        return defaults.bool(forKey: "notifications.amounts.v2." + store.network.rawValue)
    }

    func setAmountsEnabled(_ requested: Bool) {
        guard !working, let store, !requested || (enabled && amountsAvailable) else { return }
        notice = nil
        let network = store.network.rawValue
        do {
            // Every opt-in starts a fresh epoch. Never enroll old invoices.
            try receiptLedger.revoke(network: network)
            if requested {
                try receiptLedger.ensureConsent(network: network, now: Int64(Date().timeIntervalSince1970))
            }
            defaults.set(requested, forKey: "notifications.amounts.v2." + network)
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
    /// Only an eligible background callback may prepare a cold wallet.
    func retainWarmStore(_ store: WalletStore) { self.store = store }

    func attach(_ store: WalletStore) {
        self.store = store
        if enabled { registerDevice() }
        reconcile()
    }

    func registered(token: Data) {
        self.token = token.map { String(format: "%02x", $0) }.joined()
        reconcile()
    }

    /// User-requested repair does not reuse an already-attested Apple key.
    func resetSetup() async {
        guard !working, enabled, let store, let configuration = configurationForStore(store) else { return }
        guard let token else {
            registerDevice()
            status = "Waiting for device registration."
            return
        }
        working = true
        do {
            try await relay(configuration).reenroll(token: token)
            status = "Device enrollment replaced. Finishing notification setup."
        } catch {
            status = "Couldn’t replace notification setup. Open the wallet to retry."
        }
        working = false
        reconcile()
    }

    func registrationFailed() { status = "Couldn’t register this device. Try again in Settings." }

    func setEnabled(_ requested: Bool) async {
        guard !working else { return }
        notice = nil
        guard let store else { notice = unavailableMessage; return }
        let network = store.network.rawValue
        if requested {
            guard available else { notice = unavailableMessage; return }
            working = true
            status = "Waiting for notification permission…"
            do {
                let allowed = try await authorize()
                working = false
                guard allowed else {
                    permissionFailed("Allow notifications in iOS Settings, then try again.")
                    return
                }
                // Permission is installation-wide; intent stays with the network
                // selected when the user tapped, even if the system sheet outlives it.
                defaults.set(true, forKey: preference(network))
                registerDevice()
            } catch {
                permissionFailed("Couldn’t request notification permission. Try again.")
                return
            }
        } else {
            // Keep metadata until relay and any bound producer both acknowledge.
            defaults.set(false, forKey: preference(network))
            try? receiptLedger.revoke(network: network)
        }
        objectWillChange.send()
        reconcile()
    }

    /// Passive reconciliation may update setup status but must not erase the
    /// explanation of a failed user action. Drain coalesced cleanup separately.
    private func permissionFailed(_ message: String) {
        notice = message
        working = false
        if reconcileAgain { reconcileAgain = false; reconcile() }
    }

    private func revokeRoute(_ route: WalletNotificationRoute, store: WalletStore) async throws -> Bool {
        let complete = try await route.revoke(currentNetwork: store.network.rawValue,
                               currentIdentity: store.notificationIdentity) {
            try await self.relay(route.relay).revoke(routeId: route.id)
        } producer: { id in
            try await store.removeNotification(id, source: route.source,
                                               network: route.network, identity: route.identity)
        }
        if complete { removeRoute(route.id) }
        return complete
    }

    func reconcile() {
        openPendingTap()
        if working { reconcileAgain = true; return }
        guard UIApplication.shared.applicationState == .active, let store else { return }
        let configuration = configurationForStore(store)
        let network = store.network.rawValue
        let desired = defaults.bool(forKey: preference(network))
        working = true
        if desired { status = "Setting up notifications…" }
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
                if !desired && !obsolete.isEmpty { status = "Turning off notifications…" }
                var previousExpiry: Int64?
                var cleanupPending = false
                try await WalletNotificationRoute.revokeAll(obsolete) { route in
                    do {
                        if !(try await revokeRoute(route, store: store)) { cleanupPending = true }
                    } catch NotificationRelayError.previousInstallationExpires(let expiry) where desired {
                        // A destroyed key cannot revoke another installation.
                        // Keep its metadata until expiry while setting up the
                        // current wallet with a new attested key.
                        previousExpiry = max(previousExpiry ?? 0, expiry)
                    }
                }
                if !desired {
                    status = cleanupPending ? "Turning off is pending. Open the matching wallet to finish." : "Notifications are off."
                    return
                }
                guard let configuration else {
                    status = unavailableMessage
                    return
                }
                let client = relay(configuration)
                guard let token else {
                    registerDevice()
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
                        let complete = try await revokeRoute(route, store: store)
                        status = complete ? "Notifications are off." : "Turning off is pending. Open the matching wallet to finish."
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
                    let response = try await store.bindNotification(grant, source: source, configuration: configuration,
                                                                    network: network, identity: identity)
                    try await client.bind(grant: grant, offer: grant.offer(for: source), result: response)
                    var bound = route
                    bound.subscriptionID = grant.subscriptionId
                    bound.boundGrant = WalletNotificationRoute.fingerprint(grant)
                    bound.presentation = grant.presentation ?? "generic"
                    bound.boundExpiresAt = response.expiresAtUnix
                    try updateRoute(bound)
                }
                status = cleanupPending ? "Notifications are on. Previous wallet cleanup is pending." :
                    previousExpiry == nil ? (amountsEnabled && amountsAvailable ?
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
              let configuration = configurationForStore(store),
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
        if let store {
            DiagnosticJournal.shared.finish(id: windowID, network: store.network.rawValue, status: "iOS window expired")
        }
        guard activeReceiptWindow == windowID else { return }
        await store?.cancelReceiptWindow(windowID)
    }

    /// Only the relay's payment marker can authorize a local fallback. A wake
    /// or already-visible remote alert never creates another local banner.
    func received(_ userInfo: [AnyHashable: Any], windowID: String,
                  lease: ReceiptFetchLease) async -> Bool {
        received(userInfo)
        guard !lease.expired, UIApplication.shared.applicationState != .active else { return false }
        let diagnosticNetwork = store?.network.rawValue
        if let diagnosticNetwork {
            let payment = ReceiptPaymentHint(userInfo: userInfo)
            let known = payment.flatMap { validPaymentRoute($0.routeID) } ??
                WalletNotificationRoute.parsePush(userInfo).flatMap { validWakeRoute($0) }
            DiagnosticJournal.shared.begin(id: windowID, network: diagnosticNetwork,
                trigger: known == nil ? "Unrecognized push" : payment == nil ? "Relay wake" : "Payment hint",
                wake: .init(entryPoint: "APNs background callback", source: known?.source.rawValue))
        }
        defer {
            if let diagnosticNetwork {
                DiagnosticJournal.shared.finish(id: windowID, network: diagnosticNetwork, status: "No native window")
            }
        }
        guard let hint = ReceiptPaymentHint(userInfo: userInfo) else {
            guard let id = WalletNotificationRoute.parsePush(userInfo), let route = validWakeRoute(id) else {
                if let diagnosticNetwork { DiagnosticJournal.shared.event(id: windowID, network: diagnosticNetwork, label: "No eligible local wake route") }
                return false
            }
            return await runMaintenance(windowID: windowID, lease: lease, expectedIdentity: route.identity)
        }
        guard let store, let route = validPaymentRoute(hint.routeID),
              receiptLedger.reservePresentation(routeID: hint.routeID, eventHash: hint.eventHash) else { return false }
        defer { receiptLedger.releasePresentation(routeID: hint.routeID, eventHash: hint.eventHash) }
        // One callback owns this event across awaits. Other events can still
        // use generic presentation while the native window belongs elsewhere.
        if matchesSelectedConnection(route, store: store), activeReceiptWindow == nil {
            activeReceiptWindow = windowID
            _ = await store.prepareBackgroundWallet(windowID: windowID, lease: lease, expectedIdentity: route.identity)
            if activeReceiptWindow == windowID { activeReceiptWindow = nil }
        }
        guard !lease.expired else { return false }
        let currentRoute = isCurrentPaymentRoute(route, store: store)
        let id = hint.routeID
        let eventHash = hint.eventHash
        let generation = store.notificationGeneration
        let now = Int64(Date().timeIntervalSince1970)
        var enrollment: ReceiptEnrollment?
        do { enrollment = try receiptLedger.enrolled(routeID: id, eventHash: eventHash, now: now) }
        catch { return false }
        var result: ReceiptWindowResult?
        if currentRoute, amountsEnabled, amountsAvailable, route.presentation == "receipt_hint",
           let enrolled = enrollment, enrolled.identity == store.notificationRuntimeIdentity,
           enrolled.configuration == route.configuration, activeReceiptWindow == nil {
            activeReceiptWindow = windowID
            await store.setReceiptBackgroundMode(enabled: true)
            result = try? await store.runReceiptWindow(ReceiptWindowRequest(
                windowID: windowID, reference: enrolled.reference,
                createdAfterUnix: enrolled.consent.createdAfterUnix
            ), identity: enrolled.identity)
            if activeReceiptWindow == windowID { activeReceiptWindow = nil }
        } else if currentRoute {
            _ = await runMaintenance(windowID: windowID, lease: lease)
        }
        guard !lease.expired, store.notificationGeneration == generation,
              validPaymentRoute(id) != nil else { return false }
        // Consent or account changes remove amount authority. The app lock is
        // separate: amounts still require the user's explicit notification consent.
        if !isCurrentPaymentRoute(route, store: store) || !amountsEnabled || !amountsAvailable ||
            enrollment?.identity != store.notificationRuntimeIdentity ||
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
            DiagnosticJournal.shared.event(id: windowID, network: route.network, label: "Local notification inserted")
            return result?.receipts.contains(where: { $0.state == "complete" }) == true
        } catch { return false }
    }

    /// A scheduled opportunity needs no notification consent: it advances only
    /// persisted wallet work and never creates a local payment alert.
    func runMaintenance(windowID: String, lease: ReceiptFetchLease, expectedIdentity: String? = nil) async -> Bool {
        if let store {
            DiagnosticJournal.shared.begin(id: windowID, network: store.network.rawValue, trigger: "Scheduled opportunity")
        }
        defer {
            if let store {
                DiagnosticJournal.shared.finish(id: windowID, network: store.network.rawValue, status: "No native window")
            }
        }
        guard !lease.expired, activeReceiptWindow == nil, let store else { return false }
        activeReceiptWindow = windowID
        defer { if activeReceiptWindow == windowID { activeReceiptWindow = nil } }
        // Cancellation can arrive during this pause; the unique-ID fence still
        // rejects the native invocation before admission.
        guard await store.prepareBackgroundWallet(windowID: windowID, lease: lease, expectedIdentity: expectedIdentity),
              !lease.expired else { return false }
        let result = try? await store.runMaintenanceWindow(windowID)
        return (result?.batches ?? 0) > 0 || (result?.maintenanceChecked ?? 0) > 0
    }

    private func validWakeRoute(_ id: String) -> WalletNotificationRoute? {
        guard let store, enabled, let configuration = configurationForStore(store) else { return nil }
        return routes().first {
            $0.id == id && $0.network == store.network.rawValue &&
            $0.configuration == configuration.storageAccount && $0.boundGrant != nil &&
            ($0.boundExpiresAt ?? 0) > Int64(Date().timeIntervalSince1970) &&
            (store.notificationKnownIdentity == nil || $0.identity == store.notificationKnownIdentity)
        }
    }

    /// A saved subscribed network keeps generic presentation even when another
    /// network or custom endpoint is selected. Amount work stays current-only.
    func validPaymentRoute(_ id: String) -> WalletNotificationRoute? {
        routes().first {
            $0.id == id && $0.source == .swapServer &&
            defaults.bool(forKey: preference($0.network))
        }
    }

    private func matchesSelectedConnection(_ route: WalletNotificationRoute, store: WalletStore) -> Bool {
        route.network == store.network.rawValue &&
        route.configuration == store.notificationConfiguration?.storageAccount
    }

    private func isCurrentPaymentRoute(_ route: WalletNotificationRoute, store: WalletStore) -> Bool {
        matchesSelectedConnection(route, store: store) && route.identity == store.notificationRuntimeIdentity
    }
}
