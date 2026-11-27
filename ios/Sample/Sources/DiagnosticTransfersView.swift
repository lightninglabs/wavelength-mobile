import SwiftUI
import WalletKit

enum DiagnosticTransferRail: String, CaseIterable {
    case oor = "OOR"
    case lightning = "Lightning"
    case credit = "Credit"

    var view: DiagnosticView {
        switch self {
        case .oor: return .oor
        case .lightning: return .swaps
        case .credit: return .credits
        }
    }

    var listKey: String {
        switch self {
        case .oor: return "sessions"
        case .lightning: return "swaps"
        case .credit: return "operations"
        }
    }

    var idKey: String {
        switch self {
        case .oor: return "session_id"
        case .lightning: return "payment_hash"
        case .credit: return "operation_id"
        }
    }
}

struct DiagnosticTransfersView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var query = Query(rail: .oor)
    @State private var showsRecoveryPackages = false
    @State private var loadedValue: DiagnosticValue = .null
    @State private var loadError: String?
    @State private var loadedQuery: Query?

    private struct Query: Equatable {
        let rail: DiagnosticTransferRail
        var previousTokens: [String] = []
        var token: String { previousTokens.last ?? "" }
    }

    private var rail: DiagnosticTransferRail { query.rail }
    private var railSelection: Binding<DiagnosticTransferRail> {
        Binding(get: { rail }, set: { selection in
            query = Query(rail: selection)
            showsRecoveryPackages = false
        })
    }
    private var value: DiagnosticValue { loadedQuery == query ? loadedValue : .null }
    private var error: String? { loadedQuery == query ? loadError : nil }
    private var items: [DiagnosticValue] { value[rail.listKey].items }

    var body: some View {
        WalletPage {
            Picker("Type", selection: railSelection) {
                ForEach(DiagnosticTransferRail.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }.pickerStyle(.segmented)
            if value == .null && error == nil { ProgressView() }
            if rail == .credit, value != .null {
                DiagnosticRow(label: "Available", value: WalletFormatting.sats(value["available_sat"].int))
                DiagnosticRow(label: "Reserved", value: WalletFormatting.sats(value["reserved_sat"].int))
            }
            if value["diagnostic"]["package_evidence_unavailable"].flag {
                DiagnosticFailure(message: "Ark recovery evidence could not be loaded.")
            }
            if value["diagnostic"]["swap_evidence_unavailable"].flag {
                DiagnosticFailure(message: "Related Lightning swaps could not be loaded.")
            }
            let groups = DiagnosticTransferGroups(items, rail: rail)
            transferRows(groups.visible)
            if !groups.recovery.isEmpty {
                DisclosureGroup("Ark recovery packages (\(groups.recovery.count))", isExpanded: $showsRecoveryPackages) {
                    transferRows(groups.recovery)
                }
            }
            if value != .null && items.isEmpty { Text("No records").foregroundStyle(WalletTheme.secondary) }
            if rail == .oor {
                HStack {
                    if !query.previousTokens.isEmpty {
                        Button("Newer records") { query.previousTokens.removeLast() }
                    }
                    Spacer()
                    let next = value["next_page_token"].text
                    if !next.isEmpty {
                        Button("Older records") { query.previousTokens.append(next) }
                    }
                }
            }
            DiagnosticFailure(message: error)
        }.navigationTitle("Transfers & credit").navigationBarTitleDisplayMode(.inline)
            .task(id: query) {
                let requested = query
                await diagnosticPolling { await load(requested) }
            }
    }

    private func transferRows(_ rows: [DiagnosticValue]) -> some View {
        ForEach(diagnosticIdentified(rows, keys: [rail.idKey])) { row in
            let item = row.value
            let summary = DiagnosticTransferSummary(item, rail: rail, ledger: value["ledger_entries"].items)
            NavigationLink(destination: DiagnosticRecordView(
                title: summary.title, value: item, relatedSwap: summary.relatedSwap
            )) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(summary.title, systemImage: summary.symbol)
                        Spacer(minLength: 12)
                        if let amount = summary.amount {
                            Text(amount).multilineTextAlignment(.trailing)
                        }
                    }.font(.callout.weight(.medium))
                    if !summary.state.isEmpty {
                        Text(summary.state).font(.caption).foregroundStyle(WalletTheme.secondary)
                    }
                    if let failure = summary.failure {
                        Text(failure).font(.caption).foregroundStyle(WalletTheme.secondary)
                    }
                    Text(diagnosticShort(item[rail.idKey].text))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(WalletTheme.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            WalletDivider()
        }
    }

    private func load(_ requested: Query) async {
        guard !Task.isCancelled, requested == query else { return }
        if loadedQuery != requested {
            loadedValue = .null
            loadError = nil
            loadedQuery = requested
        }
        do {
            let value = try await store.diagnosticRead(requested.rail.view, pageToken: requested.token)
            guard !Task.isCancelled, requested == query else { return }
            loadedValue = value
            loadError = nil
        } catch {
            guard !Task.isCancelled, requested == query else { return }
            loadError = error.walletMessage
        }
    }
}

struct DiagnosticTransferGroups {
    let visible: [DiagnosticValue]
    let recovery: [DiagnosticValue]

    init(_ items: [DiagnosticValue], rail: DiagnosticTransferRail) {
        var visible = [DiagnosticValue]()
        var recovery = [DiagnosticValue]()
        for item in items {
            if rail == .oor, DiagnosticTransferSummary.isCompletedOOR(item),
               item["diagnostic"]["kind"].text == "recovery_package" {
                recovery.append(item)
            } else {
                visible.append(item)
            }
        }
        self.visible = visible
        self.recovery = recovery
    }
}

private struct DiagnosticRecordView: View {
    let title: String
    let value: DiagnosticValue
    var relatedSwap: DiagnosticValue? = nil
    @State private var share: DiagnosticShare?

    var body: some View {
        WalletPage {
            if let relatedSwap {
                NavigationLink(destination: DiagnosticRecordView(
                    title: "Lightning swap", value: relatedSwap
                )) {
                    WalletNavigationRow(title: "View Lightning swap", icon: "bolt")
                }
            }
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
    let title: String
    let symbol: String
    let amount: String?
    let state: String
    let failure: String?
    let relatedSwap: DiagnosticValue?

    init(_ value: DiagnosticValue, rail: DiagnosticTransferRail, ledger: [DiagnosticValue] = []) {
        let details = value["diagnostic"]
        let unavailable = details["amount_read_failed"].flag ? "Amount could not be read" : "Amount unavailable"
        let amount = Self.positiveAmount(value["amount_sat"]) ?? unavailable
        relatedSwap = rail == .oor && Self.isCompletedOOR(value) &&
            details["kind"].text == "lightning_receive_claim" &&
            !details["related_swap"]["payment_hash"].text.isEmpty ? details["related_swap"] : nil

        switch rail {
        case .oor:
            failure = Self.nonempty(value["failure_reason"].text)
            let phase = value["phase"].label(removing: "")
            let status = phase.isEmpty ? value["status"].label(removing: "OOR_SESSION_STATUS_") : phase
            switch Self.isCompletedOOR(value) ? details["kind"].text : "" {
            case "recovery_package":
                title = "Ark recovery package"
                symbol = "link"
                state = "Kept for wallet recovery"
                self.amount = nil
            case "stored_package":
                title = "Stored Ark package"
                symbol = "doc"
                state = "Wallet relationship unknown"
                self.amount = amount
            case "lightning_receive_claim":
                title = "Lightning receive claim"
                symbol = "bolt"
                state = status
                let claimUnavailable = details["claimed_amount_read_failed"].flag
                    ? "Amount could not be read" : "Amount unavailable"
                self.amount = Self.positiveAmount(details["claimed_amount_sat"])
                    .map { "Claimed to wallet · \($0)" } ?? claimUnavailable
            default:
                (title, symbol) = Self.direction(value["direction"].text)
                state = status
                self.amount = amount
            }
        case .lightning:
            (title, symbol) = Self.direction(value["direction"].text)
            self.amount = amount
            state = value["state"].label(removing: "SWAP_STATE_")
            failure = Self.nonempty(value["terminal_reason"].text)
        case .credit:
            let type = value["type"].text
            let rawState = value["state"].text
            (title, symbol) = Self.creditTitle(type)
            state = Self.creditState(value["state"])
            failure = Self.nonempty(value["last_error"].text)

            let operationID = value["operation_id"].text
            let direction = rawState == "CREDIT_OPERATION_STATE_CREDITED" ? "credit" : "debit"
            let postedStates = ["CREDIT_OPERATION_STATE_CREDITED", "CREDIT_OPERATION_STATE_DEBITED",
                                "CREDIT_OPERATION_STATE_REDEEMED"]
            let entries = ledger.filter {
                $0["operation_id"].text == operationID && $0["direction"].text == direction
            }
            if postedStates.contains(rawState), !operationID.isEmpty, entries.count == 1,
               let posted = Self.positiveAmount(entries[0]["amount_sat"]) {
                self.amount = "Posted · \(posted)"
            } else if Self.positiveAmount(value["amount_sat"]) != nil {
                self.amount = "Operation amount · \(amount)"
            } else {
                self.amount = unavailable
            }
        }
    }

    static func isCompletedOOR(_ value: DiagnosticValue) -> Bool {
        value["status"].text == "OOR_SESSION_STATUS_COMPLETED" && value["failure_reason"].text.isEmpty
    }

    private static func positiveAmount(_ value: DiagnosticValue) -> String? {
        value.int > 0 ? WalletFormatting.sats(value.int) : nil
    }

    private static func nonempty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    private static func direction(_ direction: String) -> (String, String) {
        switch direction {
        case "OOR_SESSION_DIRECTION_OUTGOING", "SWAP_DIRECTION_PAY":
            return ("Outgoing", "arrow.up.right")
        case "OOR_SESSION_DIRECTION_INCOMING", "SWAP_DIRECTION_RECEIVE":
            return ("Incoming", "arrow.down.left")
        default:
            return ("Direction unknown", "arrow.left.arrow.right")
        }
    }

    private static func creditTitle(_ type: String) -> (String, String) {
        switch type {
        case "CREDIT_OPERATION_TYPE_FUNDING": return ("Credit funding", "plus.circle")
        case "CREDIT_OPERATION_TYPE_REDEMPTION": return ("Credit redemption", "arrow.down.left")
        case "CREDIT_OPERATION_TYPE_PAY": return ("Credit payment", "arrow.up.right")
        case "CREDIT_OPERATION_TYPE_RECEIVE": return ("Credit attached to receive", "link")
        default: return ("Credit operation", "arrow.left.arrow.right")
        }
    }

    private static func creditState(_ value: DiagnosticValue) -> String {
        switch value.text {
        case "CREDIT_OPERATION_STATE_RESERVED": return "Credits reserved"
        case "CREDIT_OPERATION_STATE_RELEASED": return "Reservation released"
        case "CREDIT_OPERATION_STATE_SENDING_OOR": return "Sending to Ark"
        case "CREDIT_OPERATION_STATE_PAYING_LIGHTNING": return "Paying Lightning"
        default: return value.label(removing: "CREDIT_OPERATION_STATE_")
        }
    }
}

func diagnosticFieldLabel(_ key: String) -> String {
    if key == "failed_before_ponr" { return "Failed before funds were committed" }
    if key == "vhtlc_outpoint" { return "vHTLC outpoint" }
    return key.replacingOccurrences(of: "_", with: " ").capitalized
}
