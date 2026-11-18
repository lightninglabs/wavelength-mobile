import SwiftUI
import WalletKit

struct ActivityDetailView: View {
    @EnvironmentObject private var store: WalletStore
    let entry: Entry
    @State private var details = false
    private var currentEntry: Entry { store.activityEntry(id: entry.id) ?? entry }

    var body: some View {
        WalletPage {
            WalletAmount(amount: abs(currentEntry.amountSat))
            if !currentEntry.note.isEmpty { Text(currentEntry.note).foregroundStyle(WalletTheme.secondary) }
            WalletStatus(text: currentEntry.displayStatus,
                         pending: currentEntry.showsActivityProgress,
                         complete: currentEntry.status == "complete", failed: currentEntry.status == "failed")
            if let date = WalletFormatting.date(currentEntry.createdAt) {
                Text(date).font(.subheadline).foregroundStyle(WalletTheme.secondary)
            }
            if currentEntry.feeSat > 0 {
                HStack { Text("Fee"); Spacer(); Text(WalletFormatting.sats(currentEntry.feeSat)) }
            }
            if let reason = currentEntry.failureReason, !reason.isEmpty {
                Text(PaymentFailure.message(reason))
                    .foregroundStyle(currentEntry.isExpiredInvoice ? WalletTheme.secondary : .red)
            }
            if currentEntry.isAwaitingIncomingPayment, let request = currentEntry.request {
                if !request.lightningInvoice.isEmpty {
                    RequestQRCodeCard(value: request.lightningInvoice)
                } else if !request.onchainAddress.isEmpty {
                    RequestQRCodeCard(value: request.onchainAddress)
                }
            }
            DisclosureGroup("Details", isExpanded: $details) {
                VStack(alignment: .leading, spacing: 20) {
                    if let reason = currentEntry.failureReason,
                       let detail = PaymentFailure.technicalDetails(reason) {
                        ValueRow(label: "Error", value: detail, copyable: true)
                    }
                    ForEach(WalletActivityPresentation.creditTopups(for: currentEntry, in: store.history.entries)) { topup in
                        NavigationLink(destination: ActivityDetailView(entry: topup)) {
                            HStack {
                                Text("Credit top-up")
                                Spacer()
                                Text(WalletFormatting.sats(abs(topup.amountSat)))
                                Image(systemName: "chevron.right").font(.caption)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    ValueRow(label: "Network", value: currentEntry.activityRailLabel)
                    if !currentEntry.counterparty.isEmpty {
                        ValueRow(label: "Destination", value: currentEntry.counterparty, copyable: true)
                    }
                    if let progress = currentEntry.progress {
                        ValueRow(label: "Phase", value: progress.phaseLabel.isEmpty ? progress.phase : progress.phaseLabel)
                        if !progress.txid.isEmpty {
                            ValueRow(label: "Transaction", value: progress.txid, copyable: true)
                            if let url = store.transactionExplorerURL(txid: progress.txid) { Link("View transaction", destination: url) }
                        }
                        if !progress.paymentHash.isEmpty { ValueRow(label: "Payment hash", value: progress.paymentHash, copyable: true) }
                        if !progress.vtxoOutpoint.isEmpty { ValueRow(label: "Outpoint", value: progress.vtxoOutpoint, copyable: true) }
                        if !progress.preimage.isEmpty { ValueRow(label: "Payment proof", value: progress.preimage, copyable: true) }
                    }
                    if let request = currentEntry.request {
                        if !request.lightningInvoice.isEmpty { ValueRow(label: "Invoice", value: request.lightningInvoice, copyable: true) }
                        if !request.onchainAddress.isEmpty { ValueRow(label: "Bitcoin address", value: request.onchainAddress, copyable: true) }
                    }
                    ValueRow(label: "Reference", value: currentEntry.id, copyable: true)
                }.padding(.top, 20)
            }
        }
        .navigationTitle(currentEntry.kind == "exit" ? "Exit" : "Payment")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("activity.detail")
    }
}

struct ActivityHistoryRows: View {
    @EnvironmentObject private var store: WalletStore
    var showsEmpty = true

    var body: some View {
        VStack(spacing: 0) {
            if #available(iOS 17, *) {
                rows.scrollTargetLayout()
            } else {
                rows
            }
            footer
        }
    }

    private var rows: some View {
        LazyVStack(spacing: 0) {
            ForEach(store.visibleActivity) { entry in
                VStack(spacing: 0) {
                    NavigationLink(destination: ActivityDetailView(entry: entry)) {
                        ActivityRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("activity.entry")
                    WalletDivider()
                }.id(entry.id)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let history = store.history
        if history.isLoading || (history.next == .first && !history.failed) {
            WalletLoadingIndicator(label: history.next == .first ? "Loading activity" : "Loading older activity")
                .frame(maxWidth: .infinity, minHeight: 52)
                .accessibilityIdentifier("activity.loading")
        } else if history.next != .end {
            if history.failed {
                Text(history.next == .first ? "Couldn’t load activity" : "Couldn’t load older activity")
                    .font(.subheadline).foregroundStyle(WalletTheme.secondary)
            }
            Button(history.failed ? "Retry" : "Load older activity") {
                Task { await store.loadOlderActivity() }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("activity.loadOlder")
        } else if !store.visibleActivity.isEmpty || showsEmpty {
            Text(store.visibleActivity.isEmpty ? "No activity" : "End of activity")
                .font(.subheadline).foregroundStyle(WalletTheme.secondary)
                .padding(.vertical, 16)
        }
    }
}
