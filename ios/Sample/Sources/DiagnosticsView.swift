import SwiftUI
import WalletKit

struct DiagnosticsView: View {
    @EnvironmentObject private var store: WalletStore
    @ObservedObject private var journal = DiagnosticJournal.shared
    @State private var info: DiagnosticValue = .null
    @State private var updated: Date?
    @State private var error: String?
    @State private var share: DiagnosticShare?

    var body: some View {
        WalletPage {
            HStack {
                WavelengthMark(size: 32)
                Text("Diagnostics").font(.largeTitle.weight(.semibold))
                Spacer()
                Text(store.network.rawValue.capitalized).font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(WalletTheme.surface, in: Capsule())
            }
            NavigationLink(destination: DiagnosticObjectView(title: "Runtime", view: .info)) {
                VStack(spacing: 16) {
                    DiagnosticRow(label: "Wallet", value: info["wallet_state"].text.isEmpty ? "Loading" : info["wallet_state"].label(removing: "WALLET_STATE_"))
                    DiagnosticRow(label: "Chain tip", value: info["block_height"].text.isEmpty ? "…" : info["block_height"].text)
                    DiagnosticRow(label: "Mailbox", value: updated == nil ? "…" : info["server_connected"].flag ? "Active" : "Paused")
                    DiagnosticRow(label: "Updated", value: updated?.formatted(date: .omitted, time: .standard) ?? "…")
                }
            }.buttonStyle(.plain)
            WalletDivider()
            NavigationLink(destination: DiagnosticVTXOsView()) {
                WalletNavigationRow(title: "VTXOs", icon: "square.3.layers.3d")
            }.accessibilityIdentifier("diagnostics.vtxos")
            NavigationLink(destination: DiagnosticRoundsView()) {
                WalletNavigationRow(title: "Rounds", icon: "circle.dotted")
            }.accessibilityIdentifier("diagnostics.rounds")
            NavigationLink(destination: DiagnosticTransfersView()) {
                WalletNavigationRow(title: "Transfers & credit", icon: "arrow.up.arrow.down")
            }
            NavigationLink(destination: DiagnosticBackgroundView()) {
                WalletNavigationRow(title: "Background", icon: "clock")
            }.accessibilityIdentifier("diagnostics.background")
            NavigationLink(destination: DiagnosticLogsView()) {
                WalletNavigationRow(title: "Logs", icon: "text.alignleft")
            }.accessibilityIdentifier("diagnostics.logs")
            WalletDivider()
            NavigationLink(destination: DiagnosticObjectView(title: "Balance breakdown", view: .balance)) {
                WalletNavigationRow(title: "Balance breakdown", icon: "chart.bar.xaxis")
            }
            if !info["identity_pubkey"].text.isEmpty {
                DiagnosticIdentifier(label: "Client ID", value: info["identity_pubkey"].text)
            }
            DiagnosticFailure(message: error)
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
            Button { share = .init(text: info.pretty) } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share runtime diagnostics").disabled(updated == nil)
        }}
        .sheet(item: $share) { DiagnosticShareSheet(text: $0.text) }
        .task { await diagnosticPolling { await load() } }
    }

    private func load() async {
        do {
            let snapshot = try await store.diagnosticRead(.info)
            try Task.checkCancellation()
            info = snapshot; updated = Date(); error = nil
        } catch { if !Task.isCancelled { self.error = error.walletMessage } }
    }
}

struct DiagnosticObjectView: View {
    @EnvironmentObject private var store: WalletStore
    let title: String
    let view: DiagnosticView
    @State private var value: DiagnosticValue = .null
    @State private var error: String?

    var body: some View {
        WalletPage {
            if value == .null && error == nil { ProgressView() }
            ForEach(value.fields.keys.sorted(), id: \.self) { key in
                if case .object = value[key] {
                    DisclosureGroup(key.replacingOccurrences(of: "_", with: " ").capitalized) { DiagnosticRaw(value: value[key]) }
                } else if case .array = value[key] {
                    DisclosureGroup(key.replacingOccurrences(of: "_", with: " ").capitalized) { DiagnosticRaw(value: value[key]) }
                } else {
                    DiagnosticRow(label: key.replacingOccurrences(of: "_", with: " ").capitalized,
                                  value: value[key].text.isEmpty ? "Not available" : value[key].text)
                }
            }
            DiagnosticRaw(value: value)
            DiagnosticFailure(message: error)
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .task { await diagnosticPolling { await load() } }
    }
    private func load() async {
        do {
            let result = try await store.diagnosticRead(view)
            try Task.checkCancellation()
            value = result; error = nil
        } catch { if !Task.isCancelled { self.error = error.walletMessage } }
    }
}
