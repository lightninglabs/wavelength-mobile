import SwiftUI
import WalletKit

struct RecoveryOptionsView: View {
    @EnvironmentObject private var store: WalletStore
    var body: some View {
        WalletPage {
            NavigationLink(destination: UnilateralExitView()) {
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
            if !store.unresolvedDispatches.isEmpty || !store.unresolvedSweeps.isEmpty {
                WalletDivider()
                NavigationLink(destination: PaymentChecksView()) {
                    WalletNavigationRow(title: "Payment checks", icon: "questionmark.circle")
                }
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

struct SweepWalletView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var destination = ""
    @State private var preview: SweepPreview?
    @State private var error: String?
    @State private var loading = false
    @State private var confirmsSeparateTransfer = false
    var body: some View {
        WalletPage {
            if let operation = store.sweepOperation {
                WalletAmount(amount: operation.amountSat)
                WalletStatus(text: operation.status, pending: operation.status == "Checking transfer" || operation.status == "In progress",
                             complete: operation.status == "Complete", failed: operation.status == "Action needed")
                if !operation.txid.isEmpty, let url = store.transactionExplorerURL(txid: operation.txid) { Link("Details", destination: url) }
                if let message = operation.error { Text(message).font(.footnote).foregroundStyle(WalletTheme.secondary) }
                if !operation.txid.isEmpty {
                    Button("New transfer") { store.finishSweep(); preview = nil; destination = "" }
                } else {
                    Button("Check status") { Task { await store.refresh() } }
                        .buttonStyle(WalletButtonStyle(secondary: true))
                    if operation.canStartSeparateTransfer {
                        if let url = store.addressExplorerURL(address: operation.destination) { Link("Check destination", destination: url) }
                        Button("Review another transfer") { confirmsSeparateTransfer = true }
                            .disabled(!store.canChangeNetwork)
                    }
                }
            } else if let preview {
                Text("Estimated amount").foregroundStyle(WalletTheme.secondary)
                WalletAmount(amount: preview.netAmountSat)
                ValueRow(label: "To", value: destination, copyable: true)
                ValueRow(label: "Estimated fee", value: WalletFormatting.sats(preview.estimatedFeeSat))
                ValueRow(label: "Fee rate", value: "\(preview.feeRateSatPerVByte) sat/vB")
                Text("Sends all confirmed on-chain funds at this fee rate.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
                if !preview.failureReason.isEmpty { Text(preview.failureReason).foregroundStyle(.red) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
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
            .confirmationDialog("Original transfer is unconfirmed", isPresented: $confirmsSeparateTransfer,
                                titleVisibility: .visible) {
                Button("Start separate transfer", role: .destructive) {
                    store.startSeparateSweepAfterChecking()
                    preview = nil; destination = ""; error = nil
                }
                Button("Keep checking", role: .cancel) {}
            } message: {
                Text("It may still be published. Check the destination before preparing a separate transfer. The original details stay in Recovery → Payment checks.")
            }
    }
    private func call(broadcast: Bool) {
        guard !loading else { return }
        loading = true
        let address = destination
        Task {
            defer { loading = false }
            do {
                if broadcast, let preview { try await store.sweep(destination: address, preview: preview) }
                else { preview = try await store.previewSweep(destination: address) }
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
    @State private var reviewOutpoints: [String] = []
    var body: some View {
        WalletPage {
            if let operation = store.refreshOperation {
                Text("Your refresh").font(.headline)
                if operation.amountSat > 0 { WalletAmount(amount: operation.amountSat) }
                WalletStatus(text: operation.status, pending: operation.status == "In progress" || operation.status == "Checking status",
                             complete: operation.status == "Complete", failed: operation.status == "Action needed")
                if let refreshed = operation.confirmedAmountSat, refreshed > 0, operation.status != "Complete" {
                    ValueRow(label: "Refreshed", value: WalletFormatting.sats(refreshed))
                }
                if let remaining = operation.remainingAmountSat, remaining > 0 {
                    ValueRow(label: operation.canRetry == true ? "Available to refresh" : "Live amount",
                             value: WalletFormatting.sats(remaining))
                }
                if let count = operation.confirmedCount {
                    ValueRow(label: "Confirmed inputs", value: "\(count) of \(operation.outpoints.count)")
                }
                if let remaining = operation.remainingOutpoints {
                    ValueRow(label: operation.canRetry == true ? "Available inputs" : "Live inputs", value: "\(remaining.count)")
                }
                if let unresolved = operation.unresolvedInputCount {
                    ValueRow(label: "Unclassified inputs", value: "\(unresolved)")
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                if let message = store.refreshCheckError {
                    Text(message).font(.footnote).foregroundStyle(WalletTheme.secondary)
                }
                if operation.status == "Complete" || operation.canRetry == true {
                    if operation.canRetry == true {
                        Text((operation.confirmedCount ?? 0) > 0 ? "The remaining funds are available." : "Funds are available. Review a new refresh.")
                            .font(.footnote).foregroundStyle(WalletTheme.secondary)
                    }
                    Button(operation.canRetry == true ? ((operation.confirmedCount ?? 0) > 0 ? "Review remaining" : "Review again") : "New refresh") {
                        let remaining = operation.remainingOutpoints ?? operation.outpoints
                        reviewOutpoints = operation.canRetry == true ? remaining : []
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
        .task {
            if store.refreshOperation == nil { await load() }
            else { await store.checkRefreshStatus() }
        }
        .refreshable {
            if store.refreshOperation == nil { await load() }
            else { await store.checkRefreshStatus() }
        }
    }
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await store.previewRefresh(outpoints: reviewOutpoints)
            preview = result
            let selected = Set(result.queuedOutpoints ?? [])
            amount = (try await store.inventory()).filter { selected.contains($0.outpoint) }.reduce(0) { $0 + $1.amountSat }
        } catch { self.error = error.walletMessage }
    }
}
