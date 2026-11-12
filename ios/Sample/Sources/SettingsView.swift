import SwiftUI
import WalletKit

struct SettingsView: View {
    @EnvironmentObject private var store: WalletStore
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        WalletPage {
            NavigationLink(destination: SecuritySettingsView()) { settingsRow("Security", "lock") }
            WalletDivider()
            NavigationLink(destination: CreditSettingsView()) { settingsRow("Credit", "circle.grid.2x2") }
            WalletDivider()
            NavigationLink(destination: ExitWalletView(unilateral: false)) { settingsRow("Exit", "arrow.up.right.square") }
                .accessibilityIdentifier("settings.exit")
            WalletDivider()
            NavigationLink(destination: RefreshWalletView()) { settingsRow("Refresh", "arrow.triangle.2.circlepath") }
                .accessibilityIdentifier("settings.refresh")
            WalletDivider()
            NavigationLink(destination: RecoveryOptionsView()) { settingsRow("Recovery", "key") }
                .accessibilityIdentifier("settings.recovery")
            WalletDivider()
            HStack {
                Text("Appearance")
                Spacer()
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Signal Dark").tag("dark")
                    Text("Porcelain Light").tag("light")
                }.pickerStyle(.menu).labelsHidden()
                    .tint(WalletTheme.secondary)
            }
            WalletDivider()
            NavigationLink(destination: ConnectionSettingsView()) { settingsRow("Connection", "network") }
            NetworkSelectionButton()
        }
        .buttonStyle(.plain)
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
    }
    private func settingsRow(_ title: String, _ icon: String) -> some View {
        WalletNavigationRow(title: title, icon: icon)
    }
}

private struct SecuritySettingsView: View {
    @EnvironmentObject private var store: WalletStore
    var body: some View {
        WalletPage {
            Toggle(WalletAuthentication.name, isOn: Binding(get: { store.biometricUnlockEnabled },
                set: { enabled in Task { await store.setBiometricUnlock(enabled) } }))
                .disabled(store.isWorking || (!WalletAuthentication.available && !store.biometricUnlockEnabled))
                .accessibilityIdentifier("settings.biometric")
            WalletDivider()
            HStack { Text("Auto-lock"); Spacer(); Text(store.biometricUnlockEnabled ? "Immediately" : "Off").foregroundStyle(WalletTheme.secondary) }
            Text("Your wallet stays encrypted. Background updates can run while the app is locked.")
                .font(.footnote).foregroundStyle(WalletTheme.secondary)
        }.navigationTitle("Security").navigationBarTitleDisplayMode(.inline)
    }
}

struct CreditSettingsView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.presentationMode) private var presentationMode
    @State private var credit = ""
    @State private var topup = ""
    var body: some View {
        WalletPage {
            WalletAmount(amount: store.balance?.creditAvailableSat ?? 0)
            Text("Provider-held").foregroundStyle(WalletTheme.secondary)
            if let reserved = store.balance?.creditReservedSat, reserved > 0 {
                HStack { Text("Reserved"); Spacer(); Text(WalletFormatting.sats(reserved)) }
            }
            WalletField(title: "Credit use limit (sats)") { TextField("10000", text: $credit).keyboardType(.numberPad) }
            WalletField(title: "Top-up limit (sats)") { TextField("10000", text: $topup).keyboardType(.numberPad) }
            Button("Save") {
                if let use = UInt64(credit), let add = UInt64(topup) {
                    store.saveCreditLimits(use: use, topup: add)
                    presentationMode.wrappedValue.dismiss()
                }
            }.buttonStyle(WalletButtonStyle()).disabled(UInt64(credit) == nil || UInt64(topup) == nil)
        }
        .navigationTitle("Credit").navigationBarTitleDisplayMode(.inline)
        .onAppear { credit = String(store.maxCreditSat); topup = String(store.maxCreditTopupSat) }
    }
}

private struct ConnectionSettingsView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var isSaving = false
    @State private var operatorAddress = ""
    @State private var swapServerAddress = ""
    @State private var esploraURL = ""
    var body: some View {
        WalletPage {
            HStack { Text("Wallet"); Spacer(); Text(store.isReady ? "Ready" : "Connecting").foregroundStyle(WalletTheme.secondary) }
            HStack { Text("Provider"); Spacer(); Text(store.info?.serverConnected == true ? "Connected" : "Unavailable").foregroundStyle(WalletTheme.secondary) }
            if let clientID = store.info?.identityPubKey, !clientID.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(clientID)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            UIPasteboard.general.string = clientID
                            WalletFeedback.completed()
                        } label: {
                            Label("Copy client ID", systemImage: "doc.on.doc")
                        }
                        .accessibilityIdentifier("connection.copyClientID")
                    }.padding(.top, 12)
                } label: {
                    HStack {
                        Text("Client ID")
                        Spacer()
                        Text(clientID)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(WalletTheme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 130, alignment: .trailing)
                    }
                }
            }
            DisclosureGroup("Endpoints") {
                VStack(spacing: 22) {
                    Text("Leave blank to use defaults.")
                        .font(.footnote).foregroundStyle(WalletTheme.secondary)
                    WalletField(title: "Operator") { TextField(store.network.connectionDefaults.operatorAddress, text: $operatorAddress) }
                    WalletField(title: "Swap service") { TextField(store.network.connectionDefaults.swapAddress, text: $swapServerAddress) }
                    WalletField(title: "Esplora") { TextField(store.network.connectionDefaults.esploraURL, text: $esploraURL) }
                    Button("Save connection") {
                        isSaving = true
                        Task {
                            await store.saveEndpointOverrides(operatorAddress: operatorAddress,
                                                              swapServerAddress: swapServerAddress, esploraURL: esploraURL)
                            isSaving = false
                        }
                    }.buttonStyle(WalletButtonStyle()).disabled(isSaving || !store.canChangeNetwork)
                }.textInputAutocapitalization(.never).autocorrectionDisabled(true).padding(.top, 20)
            }
            if let version = store.info?.version {
                HStack { Text("Version"); Spacer(); Text(version) }.foregroundStyle(WalletTheme.secondary)
            }
            HStack { Text("Block height"); Spacer(); Text("\(store.info?.blockHeight ?? 0)") }
                .foregroundStyle(WalletTheme.secondary)
        }.navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: loadEndpoints)
            .onChange(of: store.network) { _ in loadEndpoints() }
    }
    private func loadEndpoints() {
        operatorAddress = store.operatorAddress
        swapServerAddress = store.swapServerAddress
        esploraURL = store.esploraURL
    }
}
