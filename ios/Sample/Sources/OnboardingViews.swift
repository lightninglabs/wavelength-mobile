import SwiftUI

struct WalletSetupView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var showsRestore = false
    var body: some View {
        NavigationView {
            WalletPage {
                WavelengthWordmark()
                Text("Wallet").font(.largeTitle.weight(.medium))
                Spacer(minLength: 180)
                NetworkSelectionButton()
                Button("Create wallet") { Task { await store.createWallet() } }
                    .buttonStyle(WalletButtonStyle())
                Button("Restore wallet") { showsRestore = true }.buttonStyle(WalletButtonStyle(secondary: true))
            }
            .sheet(isPresented: $showsRestore) { RestoreWalletForm() }
        }.navigationViewStyle(.stack)
    }
}

private struct RestoreWalletForm: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.presentationMode) private var presentationMode
    @State private var words = ""
    private var mnemonic: [String] { words.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }

    var body: some View {
        NavigationView {
            WalletPage {
                WalletField(title: "24 recovery words") {
                    TextEditor(text: $words).frame(minHeight: 140)
                        .textInputAutocapitalization(.never).autocorrectionDisabled(true).privacySensitive()
                }
                Button {
                    Task {
                        await store.createWallet(mnemonic: mnemonic, showBackup: false)
                        if store.phase.isWalletAvailable { presentationMode.wrappedValue.dismiss() }
                    }
                } label: {
                    if store.isWorking { ProgressView() } else { Text("Restore wallet") }
                }
                .buttonStyle(WalletButtonStyle())
                .disabled(store.isWorking || mnemonic.count != 24)
            }
            .navigationTitle("Restore").navigationBarTitleDisplayMode(.inline)
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
            Text(store.managedKeyUnavailable ? "Wallet key unavailable" : "Unlock")
                .font(.largeTitle.weight(.medium))
            Spacer(minLength: 100)
            if store.managedKeyUnavailable {
                Text("This iPhone does not have this wallet’s encryption key. Use the original iPhone to transfer your funds or export a recovery package. These wallet files have been kept.")
                    .foregroundStyle(WalletTheme.secondary)
                Text("Recovery words alone may not recover off-chain funds. An iCloud restore does not transfer the wallet key.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            } else if store.biometricUnlockEnabled {
                Image(systemName: WalletAuthentication.name == "Touch ID" ? "touchid" :
                        WalletAuthentication.name == "Face ID" ? "faceid" : "lock")
                    .font(.system(size: 64, weight: .ultraLight))
                    .frame(maxWidth: .infinity).padding(.vertical, 32)
                Button {
                    Task { await store.unlockWithBiometrics() }
                } label: {
                    if store.isWorking { ProgressView() } else { Text("Unlock with \(WalletAuthentication.name)") }
                }
                .buttonStyle(WalletButtonStyle()).disabled(store.isWorking)
                .accessibilityIdentifier("wallet.unlock.biometric")
                if store.needsPasswordMigration {
                    Button(showPassword ? "Hide password" : "Use wallet password") { showPassword.toggle() }
                }
            }
            if !store.managedKeyUnavailable && store.needsPasswordMigration && (!store.biometricUnlockEnabled || showPassword) {
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
                Text("Recovery words alone may not recover off-chain funds. Move your funds before replacing or erasing this iPhone.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
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
