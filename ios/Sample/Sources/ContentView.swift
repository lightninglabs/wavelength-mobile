import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = WalletStore()
    @State private var enteredBackground = false

    var body: some View {
        ZStack {
            content
                .environmentObject(store)
                .disabled(store.isWorking)

            if store.isWorking {
                Color.black.opacity(0.18).ignoresSafeArea()
                ProgressView()
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .task {
            #if DEBUG
            // Hosted unit tests own the native singleton and isolated wallets.
            // UI tests launch the app in a separate process without this class.
            guard NSClassFromString("XCTestCase") == nil else { return }
            #endif
            if store.phase == .idle {
                await store.start()
                #if DEBUG
                if ProcessInfo.processInfo.environment["WAVELENGTH_AUTOCREATE"] == "1",
                   store.phase == .needsSetup {
                    await store.createWallet(showBackup: false)
                }
                #endif
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                store.lockForBackground()
                enteredBackground = true
            case .active where enteredBackground:
                enteredBackground = false
                Task { await store.resumeAfterBackground() }
            default:
                break
            }
        }
        .alert("Wavelength", isPresented: alertIsPresented) {
            Button("OK", role: .cancel) { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isSessionLocked {
            UnlockWalletView()
        } else if let mnemonic = store.pendingMnemonic {
            SeedBackupView(words: mnemonic)
        } else {
            switch store.phase {
            case .idle, .starting:
                LaunchView(message: "Connecting")
            case .needsSetup:
                WalletSetupView()
            case .needsUnlock:
                UnlockWalletView()
            case .syncing, .ready:
                WalletShellView()
            case .failed(let message):
                FailureView(message: message) { store.retry() }
            }
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )
    }
}

private struct LaunchView: View {
    @EnvironmentObject private var store: WalletStore
    let message: String

    var body: some View {
        VStack(spacing: 24) {
            WavelengthMark(size: 74)
            ProgressView(message)
                .tint(WalletTheme.action)
            NetworkSelectionButton()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WalletTheme.background)
    }
}

private struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            WavelengthMark(size: 68)
            Text("Wallet unavailable")
                .font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            NetworkSelectionButton()
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WalletTheme.background)
    }
}
