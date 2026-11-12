import SwiftUI
import WalletKit

struct DiagnosticTransfersView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var rail = "OOR"
    @State private var value: DiagnosticValue = .null
    @State private var error: String?
    private var items: [DiagnosticValue] {
        value[rail == "OOR" ? "sessions" : rail == "Lightning" ? "swaps" : "operations"].items
    }

    var body: some View {
        WalletPage {
            Picker("Type", selection: $rail) {
                Text("OOR").tag("OOR")
                Text("Lightning").tag("Lightning")
                Text("Credit").tag("Credit")
            }.pickerStyle(.segmented)
            if value == .null && error == nil { ProgressView() }
            if rail == "Credit", value != .null {
                DiagnosticRow(label: "Available", value: WalletFormatting.sats(value["available_sat"].int))
                DiagnosticRow(label: "Reserved", value: WalletFormatting.sats(value["reserved_sat"].int))
            }
            ForEach(diagnosticIdentified(items, keys: [rail == "OOR" ? "session_id" : rail == "Lightning" ? "payment_hash" : "operation_id"])) { row in
                let item = row.value
                NavigationLink(destination: DiagnosticRecordView(title: rail == "Credit" ? "Credit operation" : "Transfer", value: item)) {
                    let summary = DiagnosticTransferSummary(item)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(summary.direction, systemImage: summary.symbol)
                            Spacer(minLength: 12)
                            Text(summary.amount)
                        }.font(.callout.weight(.medium))
                        Text(item[rail == "OOR" ? "phase" : "state"].text
                            .replacingOccurrences(of: "SWAP_STATE_", with: "")
                            .replacingOccurrences(of: "CREDIT_OPERATION_STATE_", with: "")
                            .replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption).foregroundStyle(WalletTheme.secondary)
                        let identifier = item[rail == "OOR" ? "session_id" : rail == "Lightning" ? "payment_hash" : "operation_id"].text
                        Text(diagnosticShort(identifier)).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(WalletTheme.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                WalletDivider()
            }
            if value != .null && items.isEmpty { Text("No records").foregroundStyle(WalletTheme.secondary) }
            DiagnosticFailure(message: error)
        }.navigationTitle("Transfers & credit").navigationBarTitleDisplayMode(.inline)
            .task(id: rail) { value = .null; await diagnosticPolling { await load() } }
    }

    private func load() async {
        do {
            let result = try await store.diagnosticRead(rail == "OOR" ? .oor : rail == "Lightning" ? .swaps : .credits)
            try Task.checkCancellation()
            value = result; error = nil
        } catch { if !Task.isCancelled { self.error = error.walletMessage } }
    }
}

private struct DiagnosticRecordView: View {
    let title: String
    let value: DiagnosticValue
    @State private var share: DiagnosticShare?

    var body: some View {
        WalletPage {
            ForEach(value.fields.keys.sorted(), id: \.self) { key in
                if !value[key].text.isEmpty {
                    if value[key].text.count > 35 {
                        DiagnosticIdentifier(label: diagnosticFieldLabel(key),
                                             value: value[key].text)
                    } else {
                        DiagnosticRow(label: diagnosticFieldLabel(key),
                                      value: value[key].text)
                    }
                }
            }
            DiagnosticRaw(value: value)
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button { share = .init(text: value.pretty) } label: { Image(systemName: "square.and.arrow.up") }
            }}
            .sheet(item: $share) { DiagnosticShareSheet(text: $0.text) }
    }
}

struct DiagnosticTransferSummary {
    let direction: String
    let symbol: String
    let amount: String

    init(_ value: DiagnosticValue) {
        switch value["direction"].text {
        case "OOR_SESSION_DIRECTION_OUTGOING", "SWAP_DIRECTION_PAY":
            direction = "Outgoing"; symbol = "arrow.up.right"
        case "OOR_SESSION_DIRECTION_INCOMING", "SWAP_DIRECTION_RECEIVE":
            direction = "Incoming"; symbol = "arrow.down.left"
        default:
            switch value["type"].text {
            case "CREDIT_OPERATION_TYPE_FUNDING":
                direction = "To credit"; symbol = "arrow.up.right"
            case "CREDIT_OPERATION_TYPE_REDEMPTION":
                direction = "From credit"; symbol = "arrow.down.left"
            case "CREDIT_OPERATION_TYPE_PAY":
                direction = "Outgoing"; symbol = "arrow.up.right"
            case "CREDIT_OPERATION_TYPE_RECEIVE":
                direction = "Incoming"; symbol = "arrow.down.left"
            default:
                direction = "Direction unknown"; symbol = "arrow.left.arrow.right"
            }
        }
        amount = value["amount_sat"].int > 0 ? WalletFormatting.sats(value["amount_sat"].int) : "Amount unavailable"
    }
}

func diagnosticFieldLabel(_ key: String) -> String {
    if key == "failed_before_ponr" { return "Failed before funds were committed" }
    return key.replacingOccurrences(of: "_", with: " ").capitalized
}
