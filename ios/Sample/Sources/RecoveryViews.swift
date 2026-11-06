import SwiftUI
import WalletKit

struct RecoveryOptionsView: View {
    @EnvironmentObject private var store: WalletStore
    var body: some View {
        WalletPage {
            NavigationLink(destination: ExitWalletView(unilateral: true)) {
                WalletNavigationRow(title: "Unilateral exit", icon: "arrow.up.right.square")
            }
                .accessibilityIdentifier("recovery.unilateral")
            WalletDivider()
            NavigationLink(destination: SweepWalletView()) {
                WalletNavigationRow(title: "Send on-chain funds", icon: "arrow.up.right")
            }
            WalletDivider()
            NavigationLink(destination: RecoveryExportView()) {
                WalletNavigationRow(title: "Export recovery data", icon: "square.and.arrow.up")
            }
            if !store.recoveryJobs.isEmpty {
                Text("In progress").font(.headline)
                ForEach(store.recoveryJobs) { job in
                    NavigationLink(destination: RecoveryStatusView(outpoint: job.outpoint, amount: job.vtxoAmountSat)) {
                        WalletNavigationRow(title: WalletFormatting.sats(job.vtxoAmountSat))
                    }
                }
            }
        }.buttonStyle(.plain).navigationTitle("Recovery").navigationBarTitleDisplayMode(.inline)
    }
}

struct ExitWalletView: View {
    @EnvironmentObject private var store: WalletStore
    let unilateral: Bool
    @State private var funds: [WalletVTXO] = []
    @State private var selected: String?
    @State private var destination = ""
    @State private var externalDestination = false
    @State private var plan: ExitPlan?
    @State private var reviewed = false
    @State private var acknowledged = false
    @State private var submitted = false
    @State private var loading = false
    @State private var error: String?
    private var fund: WalletVTXO? { funds.first { $0.outpoint == selected } }
    private var planEntry: ExitPlanEntry? { plan?.plans?.first }
    private var activityEntry: Entry? {
        store.activity.first { $0.kind == "exit" && $0.progress?.vtxoOutpoint == selected }
    }

    var body: some View {
        WalletPage {
            if submitted, let selected {
                if unilateral {
                    RecoveryStatusView(outpoint: selected, amount: fund?.amountSat ?? 0, embedded: true)
                } else {
                    WalletAmount(amount: abs(activityEntry?.amountSat ?? fund?.amountSat ?? 0))
                    WalletStatus(text: activityEntry?.displayStatus ?? "Checking status",
                                 pending: activityEntry?.status != "complete",
                                 complete: activityEntry?.status == "complete")
                    if let entry = activityEntry { NavigationLink("Details", destination: ActivityDetailView(entry: entry)) }
                    if let error { Text(error).font(.footnote).foregroundStyle(WalletTheme.secondary) }
                    Button("Check status") { Task { await store.refresh() } }.buttonStyle(WalletButtonStyle(secondary: true))
                }
            } else if reviewed, let fund {
                WalletAmount(amount: fund.amountSat)
                if unilateral { unilateralReview } else {
                    Toggle("Another Bitcoin address", isOn: $externalDestination)
                    if externalDestination {
                        WalletField(title: "Bitcoin address") {
                            TextField("Address", text: $destination).textInputAutocapitalization(.never).autocorrectionDisabled(true)
                        }
                    }
                    if !externalDestination { ValueRow(label: "To", value: "My on-chain wallet") }
                    HStack { Text("Fee estimate"); Spacer(); Text("Unavailable").foregroundStyle(WalletTheme.secondary) }
                    Button("Confirm exit", action: submit).buttonStyle(WalletButtonStyle())
                        .disabled(loading || (externalDestination && destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("exit.confirm")
                }
                if let error { Text(error).foregroundStyle(.red) }
            } else {
                Text("Choose funds").font(.title2.weight(.medium))
                if loading { ProgressView() }
                if funds.isEmpty && !loading { Text("No available funds").foregroundStyle(WalletTheme.secondary) }
                ForEach(funds, id: \.outpoint) { item in
                    Button {
                        selected = item.outpoint
                        plan = nil
                    } label: {
                        HStack {
                            Text(WalletFormatting.sats(item.amountSat))
                            Spacer()
                            Image(systemName: selected == item.outpoint ? "checkmark.circle.fill" : "circle")
                        }.padding(.vertical, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    WalletDivider()
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button(unilateral ? "Check recovery plan" : "Continue") { review() }
                    .buttonStyle(WalletButtonStyle()).disabled(fund == nil || loading)
            }
        }
        .navigationTitle(unilateral ? "Unilateral exit" : "Exit").navigationBarTitleDisplayMode(.inline)
        .task { await loadFunds() }
    }

    @ViewBuilder private var unilateralReview: some View {
        if let item = planEntry {
            if item.exitJobFound {
                NavigationLink("View existing recovery", destination: RecoveryStatusView(outpoint: item.outpoint, amount: fund?.amountSat ?? 0))
            } else if !item.canStart {
                if item.fundingShortfallSat > 0 || item.infeasibilityReason == "wallet_too_few_inputs" {
                    Text("Fund network fees").font(.headline)
                    ValueRow(label: "Additional funding", value: WalletFormatting.sats(item.fundingShortfallSat))
                    ValueRow(label: "Fee inputs needed", value: "\(item.requiredFeeUTXOCount)")
                    ValueRow(label: "Each input", value: WalletFormatting.sats(item.recommendedUTXOAmountSat))
                    ValueRow(label: "Confirmed inputs ready", value: "\(item.usableFeeUTXOCount) of \(item.requiredFeeUTXOCount)")
                    ValueRow(label: "Confirmations required", value: "\(item.requiredConfirmations)")
                    Text("Fund each required input with a separate payment.").font(.footnote).foregroundStyle(WalletTheme.secondary)
                    if !item.fundingAddress.isEmpty {
                        QRCodeView(value: item.fundingAddress).frame(width: 210, height: 210)
                            .padding(16).background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                        ValueRow(label: "Fee funding address", value: item.fundingAddress, copyable: true)
                    }
                    Button("Check funding") { review() }.buttonStyle(WalletButtonStyle()).disabled(loading)
                } else {
                    Text(item.error.isEmpty ? item.infeasibilityReason.replacingOccurrences(of: "_", with: " ").capitalized : item.error)
                        .foregroundStyle(.red)
                    Button("Check plan") { review() }.buttonStyle(WalletButtonStyle(secondary: true)).disabled(loading)
                }
            } else {
                ValueRow(label: "Destination", value: "My on-chain wallet")
                ValueRow(label: "Fee funding", value: "Ready")
                if !item.roundCommitment.isEmpty {
                    Text("These funds already belong to an active round. Starting recovery may interrupt it.")
                        .font(.footnote).foregroundStyle(WalletTheme.secondary)
                }
                Text("Includes a block waiting period. Cannot be undone once started.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
                Toggle("I understand", isOn: $acknowledged)
                Button("Start unilateral exit", action: submit).buttonStyle(WalletButtonStyle())
                    .disabled(!acknowledged || loading)
                    .accessibilityIdentifier("recovery.confirm")
            }
        }
    }

    private func loadFunds() async {
        loading = true
        defer { loading = false }
        do {
            if unilateral { funds = try await store.recoveryFunds() }
            else { funds = try await store.inventory() }
        } catch { self.error = error.walletMessage }
    }
    private func review() {
        guard let selected, !loading else { return }
        error = nil
        if !unilateral { reviewed = true; return }
        loading = true
        Task {
            defer { loading = false }
            do { plan = try await store.exitPlan(outpoint: selected); reviewed = true }
            catch { self.error = error.walletMessage }
        }
    }
    private func submit() {
        guard let selected, !loading else { return }
        loading = true
        submitted = true
        // Consuming this screen before the call prevents an ambiguous failure
        // from offering the same funds-moving action a second time.
        Task {
            defer { loading = false }
            do {
                _ = try await store.exitFunds(outpoint: selected, destination: externalDestination ? destination : "", unilateral: unilateral)
            } catch { self.error = error.walletMessage }
        }
    }
}

struct RecoveryStatusView: View {
    @EnvironmentObject private var store: WalletStore
    let outpoint: String
    let amount: Int64
    var embedded = false
    @State private var status: ExitStatusResult?
    @State private var error: String?
    var body: some View {
        Group {
            if embedded { content } else { WalletPage { content } }
        }
        .navigationTitle("Recovery").navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                do { status = try await store.recoveryStatus(outpoint: outpoint); error = nil }
                catch { self.error = error.walletMessage }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    @ViewBuilder private var content: some View {
        WalletAmount(amount: status?.status == "completed" ? status?.fees?.netRecoveredSat ?? amount : amount)
        WalletStatus(text: title, pending: status?.status != "completed" && status?.status != "failed",
                     complete: status?.status == "completed", failed: status?.status == "failed")
        if let progress = status?.progress {
            ValueRow(label: "Confirmed", value: "\(progress.confirmedTxs) of \(progress.totalTxs) transactions")
            ValueRow(label: "In flight", value: "\(progress.inFlightTxs)")
        }
        if let csv = status?.csv, !csv.mature {
            Text("\(csv.blocksRemaining) blocks remaining").font(.title2.weight(.medium))
        }
        if let fees = status?.fees {
            ValueRow(label: "Network cost so far", value: WalletFormatting.sats(fees.spentSoFarSat))
            ValueRow(label: "Total estimated cost", value: WalletFormatting.sats(fees.totalCostSat))
            ValueRow(label: fees.sweepFeeActual ? "Final sweep fee" : "Sweep fee estimate", value: WalletFormatting.sats(fees.sweepFeeSat))
        }
        if let message = status?.lastError, !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.red) }
        if let error { Text(error).font(.footnote).foregroundStyle(WalletTheme.secondary) }
        if status?.status == "completed" {
            NavigationLink("Send on-chain funds", destination: SweepWalletView())
        }
        DisclosureGroup("Details") { ValueRow(label: "Outpoint", value: outpoint, copyable: true) }
    }
    private var title: String {
        switch status?.status {
        case "materializing": return "Publishing recovery"
        case "csv_pending": return "Waiting period"
        case "sweeping": return "Final sweep"
        case "completed": return "Recovered"
        case "failed": return "Action needed"
        default: return "In progress"
        }
    }
}

struct SweepWalletView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var destination = ""
    @State private var preview: SweepPreview?
    @State private var sent: SweepPreview?
    @State private var error: String?
    @State private var loading = false
    @State private var dispatched = false
    var body: some View {
        WalletPage {
            if dispatched {
                if let sent {
                    WalletAmount(amount: sent.netAmountSat)
                    WalletStatus(text: transferComplete ? "Complete" : "In progress", pending: !transferComplete, complete: transferComplete)
                    if let url = store.transactionExplorerURL(txid: sent.txid) { Link("Details", destination: url) }
                } else { WalletStatus(text: "Checking transfer", pending: true) }
                if let error { Text(error).font(.footnote).foregroundStyle(WalletTheme.secondary) }
            } else if let preview {
                WalletAmount(amount: preview.netAmountSat)
                ValueRow(label: "To", value: destination, copyable: true)
                ValueRow(label: "Network fee", value: WalletFormatting.sats(preview.estimatedFeeSat))
                if !preview.failureReason.isEmpty { Text(preview.failureReason).foregroundStyle(.red) }
                Button("Send on-chain funds") { call(broadcast: true) }
                    .buttonStyle(WalletButtonStyle()).disabled(!preview.canBroadcast || loading)
                Button("Edit") { self.preview = nil }
            } else {
                WalletField(title: "Bitcoin destination") {
                    TextField("Address", text: $destination).textInputAutocapitalization(.never).autocorrectionDisabled(true)
                }
                Button("Preview transfer") { call(broadcast: false) }
                    .buttonStyle(WalletButtonStyle()).disabled(destination.isEmpty || loading)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if loading { ProgressView() }
        }.navigationTitle("On-chain funds").navigationBarTitleDisplayMode(.inline)
    }
    private var transferComplete: Bool {
        guard let sent else { return false }
        return store.onchainHistory.contains { $0.txid == sent.txid && ($0.status == "confirmed" || $0.status == "complete") }
    }
    private func call(broadcast: Bool) {
        guard !loading else { return }
        loading = true
        if broadcast { dispatched = true }
        Task {
            defer { loading = false }
            do {
                let result = try await store.sweep(destination: destination, broadcast: broadcast)
                if broadcast { sent = result } else { preview = result }
            } catch { self.error = error.walletMessage }
        }
    }
}

struct RecoveryExportView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var funds: [WalletVTXO] = []
    @State private var selected = Set<String>()
    @State private var loading = false
    @State private var error: String?
    @State private var export: RecoveryExportFile?
    var body: some View {
        WalletPage {
            Text("Exporting does not start an exit.").font(.footnote).foregroundStyle(WalletTheme.secondary)
            Button(selected.count == funds.count ? "Deselect all" : "Select all") {
                selected = selected.count == funds.count ? [] : Set(funds.map(\.outpoint))
            }
            ForEach(funds, id: \.outpoint) { fund in
                Button {
                    if selected.contains(fund.outpoint) { selected.remove(fund.outpoint) } else { selected.insert(fund.outpoint) }
                } label: {
                    HStack {
                        Text(WalletFormatting.sats(fund.amountSat)); Spacer()
                        Image(systemName: selected.contains(fund.outpoint) ? "checkmark.circle.fill" : "circle")
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                WalletDivider()
            }
            Button("Export package") {
                loading = true
                Task {
                    defer { loading = false }
                    do {
                        let data = try await store.exportRecovery(outpoints: selected.sorted())
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wavelength-recovery-\(UUID().uuidString).json")
                        try data.write(to: url, options: [.atomic, .completeFileProtection])
                        export = RecoveryExportFile(url: url)
                    } catch { self.error = error.walletMessage }
                }
            }.buttonStyle(WalletButtonStyle()).disabled(selected.isEmpty || loading)
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Recovery export").navigationBarTitleDisplayMode(.inline)
        .task {
            do { funds = try await store.recoveryFunds() } catch { self.error = error.walletMessage }
        }
        .sheet(item: $export, onDismiss: { export = nil }) { item in
            ShareSheet(items: [item.url]).onDisappear { try? FileManager.default.removeItem(at: item.url) }
        }
    }
    private struct RecoveryExportFile: Identifiable {
        let url: URL
        var id: URL { url }
    }
}

struct RefreshWalletView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var preview: RefreshResult?
    @State private var amount: Int64 = 0
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        WalletPage {
            if let operation = store.refreshOperation {
                if operation.amountSat > 0 { WalletAmount(amount: operation.amountSat) }
                WalletStatus(text: operation.status, pending: operation.status == "In progress" || operation.status == "Checking status",
                             complete: operation.status == "Complete", failed: operation.status == "Action needed")
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button("Check status") { Task { await store.refresh() } }.buttonStyle(WalletButtonStyle(secondary: true))
                if operation.status == "Complete" || operation.canRetry == true {
                    if operation.canRetry == true {
                        Text("Funds are available. Review a new refresh.").font(.footnote).foregroundStyle(WalletTheme.secondary)
                    }
                    Button(operation.canRetry == true ? "Review again" : "New refresh") {
                        store.clearCompletedRefresh()
                        Task { await load() }
                    }
                }
                DisclosureGroup("Details") {
                    ForEach(operation.outpoints, id: \.self) { ValueRow(label: "Selected funds", value: $0, copyable: true) }
                }
            } else if let preview {
                if amount > 0 { WalletAmount(amount: amount) }
                let inputs = preview.queuedOutpoints ?? []
                if inputs.isEmpty { Text("No funds to refresh").foregroundStyle(WalletTheme.secondary) }
                ValueRow(label: "Fee estimate", value: preview.feeEstimate?.totalFeeSat.map { WalletFormatting.sats($0) } ?? "Unavailable")
                if let message = preview.feeEstimate?.estimateError, !message.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(WalletTheme.secondary)
                }
                Button("Confirm") {
                    loading = true
                    Task {
                        defer { loading = false }
                        do { try await store.startRefresh(outpoints: inputs, amountSat: amount) }
                        catch { self.error = error.walletMessage }
                    }
                }.buttonStyle(WalletButtonStyle()).disabled(loading || inputs.isEmpty)
            } else {
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Review refresh") { Task { await load() } }.buttonStyle(WalletButtonStyle()).disabled(loading)
            }
        }
        .navigationTitle("Refresh").navigationBarTitleDisplayMode(.inline)
        .task { if store.refreshOperation == nil { await load() } }
    }
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await store.previewRefresh()
            preview = result
            let selected = Set(result.queuedOutpoints ?? [])
            amount = (try await store.inventory()).filter { selected.contains($0.outpoint) }.reduce(0) { $0 + $1.amountSat }
        } catch { self.error = error.walletMessage }
    }
}
