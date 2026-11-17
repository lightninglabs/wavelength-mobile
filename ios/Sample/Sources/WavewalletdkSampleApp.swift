import SwiftUI

@main
struct WavelengthApp: App {
    @UIApplicationDelegateAdaptor(WalletNotificationDelegate.self) private var delegate
    @StateObject private var store: WalletStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"

    init() {
        let warmStore = WalletStore()
        _store = StateObject(wrappedValue: warmStore)
        WalletNotifications.shared.retainWarmStore(warmStore)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--send-form-test") {
                    // Exercise form transitions without starting or funding a
                    // wallet. The idle store keeps payment dispatch disabled.
                    SendView().environmentObject(store)
                } else {
                    ContentView(store: store)
                }
                #else
                ContentView(store: store)
                #endif
                if scenePhase != .active {
                    PrivacyCover().accessibilityHidden(true)
                }
            }
            .tint(WalletTheme.action)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            WalletTheme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                WavelengthMark(size: 70)
                Text("wavelength").font(.title3.weight(.medium))
            }
        }
    }
}
