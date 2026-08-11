import SwiftUI
import WalletKit

struct SettingsView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var proposedMainnet = false
    @State private var isSaving = false

    var body: some View {
        Form {
            Section("Bitcoin network") {
                ForEach(WalletNetwork.selectableNetworks, id: \.rawValue) { network in
                    Button {
                        select(network)
                    } label: {
                        HStack(spacing: 12) {
                            Circle().fill(network.color).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(network.title).foregroundStyle(.primary)
                                Text(network.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.network == network {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(network.color)
                            }
                        }
                    }
                }
            }

            Section("Wallet backend") {
                Label("Esplora lightweight wallet", systemImage: "network")
                Text("Wavelength uses its in-process lwwallet backend for chain sync. No LND node or LND wallet is bundled or required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                HStack {
                    Label("Wallet", systemImage: "bitcoinsign.circle")
                    Spacer()
                    Text(store.isReady ? "Ready" : "Syncing")
                        .foregroundStyle(store.isReady ? .green : .orange)
                }
                HStack {
                    Label("Block height", systemImage: "cube")
                    Spacer()
                    Text("\(store.info?.blockHeight ?? 0)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Ark operator", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    Text(store.info?.serverConnected == true ? "Connected" : "Offline")
                        .foregroundStyle(store.info?.serverConnected == true ? .green : .secondary)
                }
            }

            Section {
                TextField("Operator host:port", text: $store.operatorAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("Swap server host:port", text: $store.swapServerAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("Esplora API URL", text: $store.esploraURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                Button {
                    isSaving = true
                    Task {
                        await store.saveEndpointOverrides()
                        isSaving = false
                    }
                } label: {
                    HStack {
                        if isSaving { ProgressView().padding(.trailing, 5) }
                        Text("Save and Restart Wallet")
                    }
                }
                .disabled(isSaving)

                Button("Use Network Defaults") {
                    store.operatorAddress = ""
                    store.swapServerAddress = ""
                    store.esploraURL = ""
                    isSaving = true
                    Task {
                        await store.saveEndpointOverrides()
                        isSaving = false
                    }
                }
                .disabled(isSaving)
            } header: {
                Text("Advanced endpoints")
            } footer: {
                if store.network == .mainnet {
                    Text("Mainnet chain sync can use the bundled Esplora default. Creating Wavelength boarding addresses requires a trusted operator; Lightning additionally requires a trusted swap endpoint. Empty service fields do not enable a public mainnet service.")
                } else if store.network == .regtest {
                    Text("Debug-only regtest requires the local stack’s operator, swap, and Esplora endpoints. Launch environment variables can supply all three.")
                } else {
                    Text("Leave fields empty to use the current defaults compiled into Wavelength. Overrides must use endpoints for \(store.network.title).")
                }
            }

            Section("Security") {
                Label("Self-custodial seed", systemImage: "key.fill")
                Label("Device-bound Keychain encryption", systemImage: "lock.iphone")
                Text("Each Bitcoin network has an isolated wallet database and encryption key. Recovery words are only shown during wallet creation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                HStack {
                    Text("Wavelength")
                    Spacer()
                    Text("1.0").foregroundStyle(.secondary)
                }
                if let version = store.info?.version, !version.isEmpty {
                    HStack {
                        Text("Embedded wallet")
                        Spacer()
                        Text(version).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Use real bitcoin on Mainnet?",
            isPresented: $proposedMainnet,
            titleVisibility: .visible
        ) {
            Button("Switch to Mainnet", role: .destructive) {
                Task { await store.switchNetwork(to: .mainnet) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mainnet uses a separate wallet and real funds. Off-chain operations remain unavailable until you configure trusted services.")
        }
    }

    private func select(_ network: WalletNetwork) {
        guard network != store.network else { return }
        if network == .mainnet {
            proposedMainnet = true
        } else {
            Task { await store.switchNetwork(to: network) }
        }
    }
}
