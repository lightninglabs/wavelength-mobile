import SwiftUI
import WalletKit

struct CooperativeExitView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var funds: [WalletVTXO] = []
    @State private var selected: Set<String> = []
    @State private var reviewed = false
    @State private var externalDestination = false
    @State private var destination = ""
    @State private var loading = false
    @State private var error: String?
    @State private var operationID: UUID?
    @State private var feeState: BatchExitFeeState = .loading
    @State private var feeAttempt = 0

    private var selection: [WalletVTXO] { funds.filter { selected.contains($0.outpoint) } }
    private var amount: Int64 { selection.reduce(0) { $0 + $1.amountSat } }
    private var fee: BatchExitFee? { if case .ready(let fee) = feeState { return fee }; return nil }
    private var feeKey: String {
        reviewed ? "\(store.network.rawValue):\(selected.sorted().joined(separator: ",")):\(feeAttempt)" : ""
    }
    private var blocked: Bool {
        store.exitBatchJournalError != nil || !selected.isDisjoint(with: store.pendingExitOutpoints)
    }

    var body: some View {
        Group {
            if let operationID {
                BatchExitStatusView(operationID: operationID)
            } else {
                WalletPage {
                    if let message = store.exitBatchJournalError {
                        Text(message).font(.footnote).foregroundStyle(WalletTheme.secondary)
                    }
                    if reviewed { review } else { fundSelection }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Exit").navigationBarTitleDisplayMode(.inline)
        .task { await loadFunds() }
        .task(id: feeKey) { await loadFees() }
    }

    @ViewBuilder private var fundSelection: some View {
        ForEach(store.exitBatches.filter(\.isPending)) { operation in
            NavigationLink(destination: BatchExitStatusView(operationID: operation.id)) {
                VStack(alignment: .leading, spacing: 2) {
                    WalletNavigationRow(title: WalletFormatting.sats(operation.amountSat))
                    Text("Exit in progress").font(.footnote).foregroundStyle(WalletTheme.secondary)
                }
            }.buttonStyle(.plain)
            WalletDivider()
        }
        Text("Choose funds").font(.title2.weight(.medium))
        if loading { ProgressView() }
        if funds.isEmpty && !loading { Text("No available funds").foregroundStyle(WalletTheme.secondary) }
        ForEach(funds, id: \.outpoint) { item in
            let unavailable = store.pendingExitOutpoints.contains(item.outpoint)
            Button {
                if selected.contains(item.outpoint) { selected.remove(item.outpoint) }
                else { selected.insert(item.outpoint) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(WalletFormatting.sats(item.amountSat))
                        Text(shortOutpoint(item.outpoint)).font(.caption.monospaced())
                            .foregroundStyle(WalletTheme.secondary)
                    }
                    Spacer()
                    if unavailable {
                        Text(store.exitBatches.flatMap(\.inputs).first {
                            $0.outpoint == item.outpoint && $0.state.isPending
                        }?.state.title ?? "Checking status")
                            .font(.footnote).foregroundStyle(WalletTheme.secondary)
                    } else {
                        Image(systemName: selected.contains(item.outpoint) ? "checkmark.circle.fill" : "circle")
                    }
                }.padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(unavailable || loading || store.exitBatchJournalError != nil)
                .accessibilityIdentifier("exit.input.\(item.outpoint)")
                .accessibilityValue(selected.contains(item.outpoint) ? "Selected" : "Not selected")
            WalletDivider()
        }
        if !selected.isEmpty {
            ValueRow(label: "Selected", value: WalletFormatting.sats(amount))
        }
        Button("Continue") { error = nil; feeState = .loading; reviewed = true }
            .buttonStyle(WalletButtonStyle()).disabled(selected.isEmpty || loading || blocked)
            .accessibilityIdentifier("exit.continue")
    }

    @ViewBuilder private var review: some View {
        WalletAmount(amount: amount)
        if externalDestination {
            WalletField(title: "To") {
                TextField("Bitcoin address", text: $destination)
                    .textInputAutocapitalization(.never).autocorrectionDisabled(true)
            }
        } else { ValueRow(label: "To", value: "My on-chain wallet") }
        Toggle("Use another address", isOn: $externalDestination).disabled(loading)
        HStack {
            Text("Estimated fee")
            Spacer()
            switch feeState {
            case .loading: ProgressView().accessibilityLabel("Estimating exit fee")
            case .ready(let estimate):
                Text(WalletFormatting.sats(estimate.totalSat)).foregroundStyle(WalletTheme.secondary)
                    .accessibilityIdentifier("exit.fee")
            case .failed: Button("Retry") { feeAttempt += 1 }
            }
        }
        if case .failed(let message) = feeState {
            Text(message).font(.footnote).foregroundStyle(WalletTheme.secondary)
        } else if let fee, !fee.canExit {
            Text("Some selected funds are too small to exit at the current fee.")
                .font(.footnote).foregroundStyle(WalletTheme.secondary)
        }
        DisclosureGroup("Details") {
            ForEach(selection, id: \.outpoint) { item in
                ValueRow(label: WalletFormatting.sats(item.amountSat), value: item.outpoint, copyable: true)
            }
            Text("The fee is an estimate. Each selected input creates a separate on-chain output. The final fee is set when the exit is confirmed.")
                .font(.footnote).foregroundStyle(WalletTheme.secondary)
        }
        Button(loading ? "Submitting…" : "Confirm exit", action: submit)
            .buttonStyle(WalletButtonStyle())
            .disabled(loading || blocked || fee?.canExit != true ||
                (externalDestination && destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            .accessibilityIdentifier("exit.confirm")
        Button("Change selection") { reviewed = false }.disabled(loading)
    }

    private func loadFunds() async {
        guard operationID == nil else { return }
        loading = true
        defer { loading = false }
        do { funds = try await store.inventory() }
        catch { self.error = error.walletMessage }
    }

    private func loadFees() async {
        guard reviewed else { return }
        let inputs = selection
        feeState = .loading
        do {
            var estimates: [ExitFeeEstimate] = []
            for input in inputs {
                try Task.checkCancellation()
                estimates.append(try await store.estimateExitFee(outpoint: input.outpoint))
            }
            try Task.checkCancellation()
            feeState = .ready(try BatchExitFee(funds: inputs, estimates: estimates))
        } catch {
            if !Task.isCancelled { feeState = .failed(error.walletMessage) }
        }
    }

    private func submit() {
        guard !loading, !blocked, fee?.canExit == true else { return }
        loading = true
        let inputs = selection
        let target = externalDestination ? destination.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        Task {
            defer { loading = false }
            do { operationID = try await store.exitBatch(funds: inputs, destination: target) }
            catch { self.error = error.walletMessage }
        }
    }
}

private enum BatchExitFeeState {
    case loading
    case ready(BatchExitFee)
    case failed(String)
}

struct BatchExitStatusView: View {
    @EnvironmentObject private var store: WalletStore
    let operationID: UUID
    private var operation: BatchExitOperation? { store.exitBatches.first { $0.id == operationID } }

    var body: some View {
        WalletPage {
            if let operation {
                WalletAmount(amount: operation.amountSat)
                ForEach(operation.inputs) { input in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(WalletFormatting.sats(input.amountSat))
                            Text(shortOutpoint(input.outpoint)).font(.caption.monospaced())
                                .foregroundStyle(WalletTheme.secondary)
                        }
                        Spacer()
                        WalletStatus(text: input.state.title, pending: input.state.isPending,
                                     complete: input.state == .complete, failed: input.state == .failed)
                    }
                    if !input.message.isEmpty {
                        Text(input.message).font(.footnote).foregroundStyle(WalletTheme.secondary)
                    }
                    WalletDivider()
                }
                if operation.inputs.contains(where: { $0.state == .checking }) {
                    Text("The result isn’t confirmed yet. Check status before trying these funds again.")
                        .font(.footnote).foregroundStyle(WalletTheme.secondary)
                }
                Button("Check status") { Task { await store.refresh() } }
                    .buttonStyle(WalletButtonStyle(secondary: true))
                DisclosureGroup("Details") {
                    if let activityID = operation.activityID,
                       let entry = store.activity.first(where: { $0.id == activityID }) {
                        NavigationLink("View activity", destination: ActivityDetailView(entry: entry))
                    }
                    if !operation.destination.isEmpty {
                        ValueRow(label: "To", value: operation.destination, copyable: true)
                    }
                    ForEach(operation.inputs) { input in
                        ValueRow(label: WalletFormatting.sats(input.amountSat), value: input.outpoint, copyable: true)
                    }
                    if let error = operation.error { Text(error).font(.footnote).foregroundStyle(WalletTheme.secondary) }
                }
                if let message = store.exitBatchJournalError { Text(message).font(.footnote).foregroundStyle(.red) }
            }
        }.navigationTitle("Exit").navigationBarTitleDisplayMode(.inline)
            .task { await store.refresh() }
    }
}

private func shortOutpoint(_ outpoint: String) -> String {
    guard let colon = outpoint.lastIndex(of: ":") else { return outpoint }
    return String(outpoint[..<colon].prefix(8)) + "…" + outpoint[colon...]
}
