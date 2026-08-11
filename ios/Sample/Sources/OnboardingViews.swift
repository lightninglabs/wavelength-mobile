import SwiftUI

struct WalletSetupView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var showingRestore = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Spacer()
                WavelengthMark(size: 86)
                VStack(spacing: 8) {
                    Text("Your bitcoin, in your hands")
                        .font(.title2.bold())
                    Text("A self-custodial Wavelength wallet, synced with Esplora and secured on this device.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                NetworkSelectionButton()

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        Task { await store.createWallet() }
                    } label: {
                        Text("Create New Wallet")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Restore from Recovery Words") {
                        showingRestore = true
                    }
                    .controlSize(.large)
                }

                Text("Wavelength never sends your seed or wallet password off this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .sheet(isPresented: $showingRestore) {
                RestoreWalletView()
                    .environmentObject(store)
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct RestoreWalletView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.presentationMode) private var presentationMode
    @State private var words = ""

    private var mnemonic: [String] {
        words.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextEditor(text: $words)
                        .frame(minHeight: 150)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .privacySensitive()
                } header: {
                    Text("Recovery words")
                } footer: {
                    Text("Enter the words in order, separated by spaces. The wallet will recover addresses using the selected \(store.network.title) network.")
                }

                Section {
                    Button("Restore Wallet") {
                        Task {
                            await store.createWallet(mnemonic: mnemonic, showBackup: false)
                            if store.phase.isWalletAvailable {
                                presentationMode.wrappedValue.dismiss()
                            }
                        }
                    }
                    .disabled(mnemonic.count < 12 || store.isWorking)
                }
            }
            .navigationTitle("Restore Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

struct UnlockWalletView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var password = ""

    var body: some View {
        VStack(spacing: 22) {
            WavelengthMark(size: 72)
            Text("Unlock Wallet").font(.title2.bold())
            Text("This wallet database was found, but its device key is unavailable. Enter the password originally used to create it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            NetworkSelectionButton()
            SecureField("Wallet password", text: $password)
                .textContentType(.password)
                .padding(13)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            Button("Unlock") {
                Task { await store.unlockWallet(password: password) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(password.isEmpty || store.isWorking)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

struct SeedBackupView: View {
    @EnvironmentObject private var store: WalletStore
    let words: [String]
    @State private var acknowledged = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Write these words down", systemImage: "exclamationmark.shield.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.orange)

                    Text("They are the only backup for your wallet. Keep them offline and never share them with anyone.")
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .trailing)
                                Text(word)
                                    .font(.body.monospaced())
                            }
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .privacySensitive()

                    Toggle("I saved these recovery words", isOn: $acknowledged)
                        .font(.body.weight(.medium))

                    Button {
                        store.acknowledgeSeedBackup()
                    } label: {
                        Text("Continue to Wallet").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!acknowledged)
                }
                .padding(22)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Wallet Backup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }
}
