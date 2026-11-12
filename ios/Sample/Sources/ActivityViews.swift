import SwiftUI
import WalletKit

struct ActivityDetailView: View {
    @EnvironmentObject private var store: WalletStore
    let entry: Entry
    @State private var details = false
    private var currentEntry: Entry { store.activity.first { $0.id == entry.id } ?? entry }

    var body: some View {
        WalletPage {
            WalletAmount(amount: abs(currentEntry.amountSat))
            if !currentEntry.note.isEmpty { Text(currentEntry.note).foregroundStyle(WalletTheme.secondary) }
            WalletStatus(text: currentEntry.displayStatus,
                         pending: currentEntry.status == "pending" && !currentEntry.isAwaitingIncomingPayment,
                         complete: currentEntry.status == "complete", failed: currentEntry.status == "failed")
            if let date = WalletFormatting.date(currentEntry.createdAt) {
                Text(date).font(.subheadline).foregroundStyle(WalletTheme.secondary)
            }
            if currentEntry.feeSat > 0 {
                HStack { Text("Fee"); Spacer(); Text(WalletFormatting.sats(currentEntry.feeSat)) }
            }
            if let reason = currentEntry.failureReason, !reason.isEmpty {
                Text(reason).foregroundStyle(currentEntry.isExpiredInvoice ? WalletTheme.secondary : .red)
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
                    ForEach(WalletActivityPresentation.creditTopups(for: currentEntry, in: store.activity)) { topup in
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
