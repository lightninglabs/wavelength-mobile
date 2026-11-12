import SwiftUI
import WalletKit

struct DiagnosticVTXOsView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var value: DiagnosticValue = .null
    @State private var query = ""
    @State private var filter = "All"
    @State private var history = false
    @State private var error: String?

    private var items: [DiagnosticValue] {
        value["vtxos"].items.filter { item in
            let matches = query.isEmpty || "\(item["outpoint"].text) \(item["round_id"].text)"
                .range(of: query, options: .caseInsensitive) != nil
            let kind = filter == "All" || (filter == "OOR" ? item["chain_depth"].int > 0 :
                ["VTXO_EXPIRY_STATUS_NEEDS_REFRESH", "VTXO_EXPIRY_STATUS_CRITICAL", "VTXO_EXPIRY_STATUS_EXPIRED"]
                    .contains(item["expiry_info"]["status"].text))
            return matches && kind
        }.sorted { $0["outpoint"].text < $1["outpoint"].text }
    }

    var body: some View {
        WalletPage {
            if value == .null && error == nil { ProgressView() }
            TextField("Outpoint or round", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(WalletTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("diagnostics.vtxoSearch")
            Picker("Filter", selection: $filter) {
                Text("All").tag("All")
                Text("OOR").tag("OOR")
                Text("Refresh due").tag("Refresh due")
            }.pickerStyle(.segmented)
            Text("\(items.count) VTXOs").font(.caption).foregroundStyle(WalletTheme.secondary)
            LazyVStack(spacing: 0) {
                ForEach(diagnosticIdentified(items, keys: ["outpoint"])) { row in
                    let item = row.value
                    NavigationLink(destination: DiagnosticVTXODetailView(initial: item)) {
                        DiagnosticVTXORow(item: item)
                    }.buttonStyle(.plain)
                    WalletDivider()
                }
            }
            if value != .null && items.isEmpty { Text("No matching VTXOs").foregroundStyle(WalletTheme.secondary) }
            DiagnosticFailure(message: error)
        }
        .navigationTitle("VTXOs").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
            Menu { Toggle("Include spent and forfeited", isOn: $history) }
                label: { Image(systemName: "line.3.horizontal.decrease") }
        }}
        .task(id: history) { await diagnosticPolling { await load() } }
    }

    private func load() async {
        do {
            let result = try await store.diagnosticRead(.vtxos, history: history)
            try Task.checkCancellation()
            value = result; error = nil
        } catch { if !Task.isCancelled { self.error = error.walletMessage } }
    }
}

private struct DiagnosticVTXORow: View {
    let item: DiagnosticValue
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item["outpoint"].text.isEmpty ? "Pending output" : diagnosticShort(item["outpoint"].text))
                    .font(.system(.caption, design: .monospaced))
                Text("\(item["chain_depth"].int > 0 ? "OOR" : "Round") · \(item["status"].label(removing: "VTXO_STATUS_"))")
                    .font(.caption).foregroundStyle(WalletTheme.secondary)
                if !item["asset_ref"].text.isEmpty {
                    Text("Asset carrier").font(.caption).foregroundStyle(WalletTheme.secondary)
                }
                Text(diagnosticExpiry(item["expiry_info"]))
                    .font(.caption).foregroundStyle(WalletTheme.secondary)
            }
            Spacer(minLength: 8)
            Text(WalletFormatting.sats(item["amount_sat"].int)).font(.callout.weight(.medium))
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(WalletTheme.secondary)
        }.padding(.vertical, 18)
    }
}

func diagnosticExpiry(_ expiry: DiagnosticValue) -> String {
    guard expiry["status"].text != "VTXO_EXPIRY_STATUS_UNKNOWN",
          expiry["batch_expiry"].int > 0, expiry["current_height"].int > 0 else { return "Expiry unknown" }
    let blocks = expiry["blocks_remaining"].int
    return blocks > 0 ? "\(blocks.formatted()) blocks left" : "Expired"
}
