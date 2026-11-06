import SwiftUI

@main
struct WavelengthApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
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
