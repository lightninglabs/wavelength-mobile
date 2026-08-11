import SwiftUI

@main
struct WavelengthApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                if scenePhase != .active {
                    PrivacyCover()
                }
            }
            .tint(.orange)
        }
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                WavelengthMark(size: 70)
                Text("Wavelength").font(.title2.bold())
            }
        }
        .accessibilityHidden(true)
    }
}
