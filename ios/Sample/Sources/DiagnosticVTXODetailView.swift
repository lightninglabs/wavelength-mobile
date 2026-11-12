import SwiftUI
import WalletKit

struct DiagnosticVTXODetailView: View {
    @EnvironmentObject private var store: WalletStore
    let initial: DiagnosticValue
    @State private var detail: DiagnosticValue = .null
    @State private var anchors: [DiagnosticValue] = []
    @State private var anchorError: String?
    @State private var error: String?
    @State private var share: DiagnosticShare?
    private var item: DiagnosticValue { detail["found"].flag ? detail["vtxo"] : initial }
    private var outpoint: String { initial["outpoint"].text }

    var body: some View {
        WalletPage {
            if !item["asset_ref"].text.isEmpty {
                Text("Carrier value").font(.caption).foregroundStyle(WalletTheme.secondary)
            }
            if item["amount_sat"] == .null { ProgressView().accessibilityLabel("Loading amount") }
            else { WalletAmount(amount: item["amount_sat"].int) }
            HStack {
                Text(item["chain_depth"].int > 0 ? "OOR" : "Round")
                Text(item["status"].label(removing: "VTXO_STATUS_"))
            }.font(.caption).foregroundStyle(WalletTheme.secondary)
            if !outpoint.isEmpty {
                DiagnosticIdentifier(label: "VTXO outpoint", value: outpoint)
            } else {
                Text("The output outpoint is assigned when its round confirms.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("Expiry").font(.headline)
                Text(diagnosticExpiry(detail["expiry_info"])).font(.title3.weight(.medium))
                DiagnosticExpiryTimeline(expiryInfo: detail["expiry_info"])
                if detail["expiry_info"]["batch_expiry"].int > 0 {
                    DiagnosticRow(label: "Expiry height", value: detail["expiry_info"]["batch_expiry"].text)
                    DiagnosticRow(label: "Current height", value: detail["expiry_info"]["current_height"].text)
                    DiagnosticRow(label: "Posture", value: detail["expiry_info"]["status"].label(removing: "VTXO_EXPIRY_STATUS_"))
                }
            }
            NavigationLink(destination: DiagnosticRefreshTimingView(outpoint: outpoint)) {
                HStack {
                    Text("Refresh timing")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(WalletTheme.secondary)
                }.padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(outpoint.isEmpty)
            WalletDivider()
            VStack(alignment: .leading, spacing: 16) {
                Text("Bitcoin anchoring outputs").font(.headline)
                ForEach(Array(anchors.enumerated()), id: \.offset) { _, anchor in
                    DiagnosticIdentifier(label: "Bitcoin outpoint", value: anchor["Outpoint"].text)
                    DiagnosticRow(label: "Output value", value: WalletFormatting.sats(anchor["AmountSat"].int))
                    if anchor["ConfirmationHeight"].int > 0 {
                        DiagnosticRow(label: "Recorded confirmation", value: anchor["ConfirmationHeight"].text)
                    }
                    DisclosureGroup("Output script") {
                        DiagnosticIdentifier(label: "Script", value: anchor["PkScript"].text)
                    }
                    WalletDivider()
                }
                if anchors.isEmpty { Text(anchorError ?? "Anchor output not available").font(.footnote).foregroundStyle(WalletTheme.secondary) }
                Text("Recorded ancestry; current spent status is not checked.")
                    .font(.caption).foregroundStyle(WalletTheme.secondary)
            }
            if !item["commitment_txid"].text.isEmpty {
                DiagnosticIdentifier(label: "Commitment transaction", value: item["commitment_txid"].text)
            }
            DiagnosticRow(label: "OOR depth", value: "\(item["chain_depth"].int) hops")
            if !item["round_id"].text.isEmpty {
                NavigationLink(destination: DiagnosticRoundDetailView(initial: .object(["round_id": item["round_id"]])) ) {
                    DiagnosticRow(label: "Round", value: diagnosticShort(item["round_id"].text))
                }
            }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 12) {
                    CopyButton(value: detail.pretty)
                    Text(detail.pretty).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 12)
            }
            NavigationLink(destination: DiagnosticLogsView(initialQuery: outpoint)) {
                Text("View related logs").frame(maxWidth: .infinity)
            }.buttonStyle(WalletButtonStyle(secondary: true)).disabled(outpoint.isEmpty)
            DiagnosticFailure(message: error)
        }
        .navigationTitle("VTXO").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
            Button { share = .init(text: diagnosticVTXOShare(item, anchors: anchors)) }
                label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share VTXO details")
        }}
        .sheet(item: $share) { DiagnosticShareSheet(text: $0.text) }
        .task { await diagnosticPolling { await load() } }
    }

    private func load() async {
        guard !outpoint.isEmpty else { return }
        do {
            let result = try await store.diagnosticRead(.vtxo, outpoint: outpoint)
            try Task.checkCancellation()
            detail = result
            error = result["found"].flag ? nil : "This VTXO is no longer in the local inventory."
        } catch { if !Task.isCancelled { self.error = error.walletMessage } }
        do {
            let result = try await store.diagnosticRead(.anchors, outpoint: outpoint)
            try Task.checkCancellation()
            anchors = result.items; anchorError = nil
        } catch { if !Task.isCancelled { anchorError = error.walletMessage } }
    }
}

func diagnosticVTXOShare(_ item: DiagnosticValue, anchors: [DiagnosticValue]) -> String {
    var lines = ["VTXO: \(item["outpoint"].text)", "Amount: \(item["amount_sat"].text) sats",
                 "Status: \(item["status"].text)", "Commitment: \(item["commitment_txid"].text)"]
    for anchor in anchors {
        lines += ["Bitcoin output: \(anchor["Outpoint"].text)", "Output value: \(anchor["AmountSat"].text) sats",
                  "Script: \(anchor["PkScript"].text)"]
    }
    lines.append("Anchor outputs are from recorded ancestry; current spent status is not checked.")
    return lines.joined(separator: "\n")
}
