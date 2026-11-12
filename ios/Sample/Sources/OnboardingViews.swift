import SwiftUI

struct WalletSetupView: View {
    @State private var setup: SetupRoute?
    var body: some View {
        NavigationView {
            WalletPage {
                WavelengthWordmark()
                Text("Wallet").font(.largeTitle.weight(.medium))
                Spacer(minLength: 180)
                NetworkSelectionButton()
                Button("Create wallet") { setup = .create }.buttonStyle(WalletButtonStyle())
                Button("Restore wallet") { setup = .restore }.buttonStyle(WalletButtonStyle(secondary: true))
            }
            .sheet(item: $setup) { route in SetupWalletForm(restore: route == .restore) }
        }.navigationViewStyle(.stack)
    }
    private enum SetupRoute: String, Identifiable {
        case create, restore
        var id: String { rawValue }
    }
}

private struct SetupWalletForm: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.presentationMode) private var presentationMode
    let restore: Bool
    @State private var words = ""
    @State private var password = ""
    @State private var confirmation = ""
    private var mnemonic: [String] { words.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }

    var body: some View {
        NavigationView {
            WalletPage {
                if restore {
                    WalletField(title: "24 recovery words") {
                        TextEditor(text: $words).frame(minHeight: 140)
                            .textInputAutocapitalization(.never).autocorrectionDisabled(true).privacySensitive()
                    }
                }
                WalletField(title: "Password") {
                    SecureField("At least 8 characters", text: $password).textContentType(.newPassword)
                }
                WalletField(title: "Confirm password") {
                    SecureField("Password", text: $confirmation).textContentType(.newPassword)
                }
                Button {
                    Task {
                        await store.createWallet(mnemonic: restore ? mnemonic : [], showBackup: !restore, password: password)
                        if store.phase.isWalletAvailable { presentationMode.wrappedValue.dismiss() }
                    }
                } label: {
                    if store.isWorking { ProgressView() } else { Text(restore ? "Restore wallet" : "Create wallet") }
                }
                .buttonStyle(WalletButtonStyle())
                .disabled(store.isWorking || password.count < 8 || password != confirmation || (restore && mnemonic.count != 24))
            }
            .navigationTitle(restore ? "Restore" : "Create wallet").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { presentationMode.wrappedValue.dismiss() } }
            }
            .interactiveDismissDisabled(store.isWorking)
        }.navigationViewStyle(.stack)
    }
}

struct UnlockWalletView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var password = ""
    @State private var showPassword = false
    var body: some View {
        WalletPage {
            WavelengthWordmark()
            Text("Unlock").font(.largeTitle.weight(.medium))
            Spacer(minLength: 100)
            if store.biometricUnlockEnabled {
                Image(systemName: WalletAuthentication.name == "Touch ID" ? "touchid" : "faceid")
                    .font(.system(size: 64, weight: .ultraLight))
                    .frame(maxWidth: .infinity).padding(.vertical, 32)
                Button {
                    Task { await store.unlockWithBiometrics() }
                } label: {
                    if store.isWorking { ProgressView() } else { Text("Unlock with \(WalletAuthentication.name)") }
                }
                .buttonStyle(WalletButtonStyle()).disabled(store.isWorking)
                .accessibilityIdentifier("wallet.unlock.biometric")
                Button(showPassword ? "Hide password" : "Use password") { showPassword.toggle() }
            }
            if !store.biometricUnlockEnabled || showPassword {
                WalletField(title: "Password") {
                    SecureField("Wallet password", text: $password).textContentType(.password)
                        .accessibilityIdentifier("wallet.unlock.password")
                }
                Button("Unlock") { Task { await store.unlockWallet(password: password) } }
                    .buttonStyle(WalletButtonStyle()).disabled(password.isEmpty || store.isWorking)
            }
            NetworkSelectionButton()
        }
        .accessibilityIdentifier("wallet.locked")
        .onChange(of: store.network) { _ in
            password = ""
            showPassword = false
        }
    }
}

struct SeedBackupView: View {
    @EnvironmentObject private var store: WalletStore
    let words: [String]
    @State private var acknowledged = false
    @State private var revealed = false
    var body: some View {
        NavigationView {
            WalletPage {
                Text("Store offline. Keep private.").foregroundStyle(WalletTheme.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 20) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        HStack(spacing: 12) {
                            Text("\(index + 1)").font(.caption).foregroundStyle(WalletTheme.secondary)
                            Text(revealed ? word : "••••••").font(.body.monospaced())
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.privacySensitive()
                Button(revealed ? "Hide words" : "Reveal words") { revealed.toggle() }
                Toggle("I saved my recovery words", isOn: $acknowledged)
                Button("Done") { store.acknowledgeSeedBackup() }
                    .buttonStyle(WalletButtonStyle()).disabled(!acknowledged)
            }
            .navigationTitle("Recovery words").navigationBarTitleDisplayMode(.inline)
        }.navigationViewStyle(.stack)
    }
}
