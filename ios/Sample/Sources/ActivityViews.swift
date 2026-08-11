import SwiftUI
import WalletKit

private enum ActivityFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case pending = "Pending"
    case received = "Received"
    case sent = "Sent"
    var id: String { rawValue }
}

struct ActivityListView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var filter: ActivityFilter = .all
    @State private var search = ""

    private var entries: [Entry] {
        store.activity.filter { entry in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .pending: matchesFilter = entry.status == "pending"
            case .received:
                matchesFilter = entry.status == "complete" && entry.isCredit
            case .sent:
                matchesFilter = entry.status == "complete" && !entry.isCredit
            }
            guard matchesFilter else { return false }
            guard !search.isEmpty else { return true }
            let needle = search.lowercased()
            return entry.id.lowercased().contains(needle) ||
                entry.note.lowercased().contains(needle) ||
                entry.counterparty.lowercased().contains(needle) ||
                entry.kind.lowercased().contains(needle)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Activity filter", selection: $filter) {
                    ForEach(ActivityFilter.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if entries.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(search.isEmpty ? "No matching activity" : "Nothing found")
                            .font(.headline)
                        Text("Completed and pending wallet operations appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        NavigationLink(destination: ActivityDetailView(entry: entry)) {
                            ActivityRow(entry: entry)
                        }
                        .accessibilityIdentifier("activity.entry")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Activity")
        .searchable(text: $search, prompt: "Search activity")
        .refreshable { await store.refresh() }
    }
}

struct ActivityDetailView: View {
    @EnvironmentObject private var store: WalletStore
    let entry: Entry
    @State private var showingInvoiceQR = false

    private var currentEntry: Entry {
        store.activity.first(where: { $0.id == entry.id }) ?? entry
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    ActivityRailIcon(entry: currentEntry, size: 54)
                    Text(currentEntry.activityTitle)
                        .font(.headline)
                    Text(currentEntry.activityAmountText)
                        .font(.title2.bold())
                        .foregroundStyle(currentEntry.activityAmountColor)
                    StatusLabel(status: currentEntry.status)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section("Details") {
                ValueRow(label: "Kind", value: currentEntry.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                ValueRow(label: "Rail", value: currentEntry.isLightningActivity ? "Lightning" : "On-chain")
                ValueRow(label: "Direction", value: currentEntry.activityDirectionLabel)
                if currentEntry.feeSat > 0 {
                    ValueRow(label: "Fee", value: WalletFormatting.sats(currentEntry.feeSat))
                }
                if let created = WalletFormatting.date(currentEntry.createdAt) {
                    ValueRow(label: "Created", value: created)
                }
                if let updated = WalletFormatting.date(currentEntry.updatedAt), updated != WalletFormatting.date(currentEntry.createdAt) {
                    ValueRow(label: "Updated", value: updated)
                }
                if !currentEntry.note.isEmpty { ValueRow(label: "Note", value: currentEntry.note) }
                if !currentEntry.counterparty.isEmpty {
                    ValueRow(label: "Counterparty", value: currentEntry.counterparty, copyable: true)
                }
            }

            if let progress = currentEntry.progress {
                Section("Progress") {
                    if !progress.phaseLabel.isEmpty || !progress.phase.isEmpty {
                        ValueRow(label: "Phase", value: (progress.phaseLabel.isEmpty ? progress.phase : progress.phaseLabel).replacingOccurrences(of: "_", with: " ").capitalized)
                    }
                    if progress.confirmationHeight > 0 {
                        ValueRow(label: "Confirmation height", value: "\(progress.confirmationHeight)")
                    }
                    if !progress.paymentHash.isEmpty {
                        ValueRow(label: "Payment hash", value: progress.paymentHash, copyable: true)
                    }
                    if !progress.txid.isEmpty {
                        ValueRow(label: "Transaction ID", value: progress.txid, copyable: true)
                        if let url = store.transactionExplorerURL(txid: progress.txid) {
                            Link("View in block explorer", destination: url)
                        }
                    }
                    if !progress.vtxoOutpoint.isEmpty {
                        ValueRow(label: "VTXO outpoint", value: progress.vtxoOutpoint, copyable: true)
                    }
                    if !progress.preimage.isEmpty {
                        ValueRow(label: "Payment preimage", value: progress.preimage, copyable: true)
                    }
                }
            }

            if let request = currentEntry.request {
                Section("Original request") {
                    ValueRow(label: "Rail", value: request.type.capitalized)
                    if !request.lightningInvoice.isEmpty {
                        ValueRow(label: "Lightning invoice", value: request.lightningInvoice, copyable: true)
                        if currentEntry.kind == "receive",
                           currentEntry.status == "pending" {
                            Button {
                                showingInvoiceQR = true
                            } label: {
                                Label("Show QR Code", systemImage: "qrcode")
                            }
                            .accessibilityIdentifier("activity.invoice.qr")
                        }
                    }
                    if !request.paymentHash.isEmpty,
                       request.paymentHash != currentEntry.progress?.paymentHash {
                        ValueRow(label: "Payment hash", value: request.paymentHash, copyable: true)
                    }
                    if !request.onchainAddress.isEmpty {
                        if let url = store.addressExplorerURL(address: request.onchainAddress) {
                            ExplorerValueRow(
                                label: "Bitcoin address",
                                value: request.onchainAddress,
                                destination: url
                            )
                        } else {
                            ValueRow(label: "Bitcoin address", value: request.onchainAddress, copyable: true)
                        }
                    }
                    if !request.arkAddress.isEmpty {
                        ValueRow(label: "Ark address", value: request.arkAddress, copyable: true)
                    }
                }
            }

            if currentEntry.status == "failed" || !(currentEntry.failureReason ?? "").isEmpty {
                Section("Failure") {
                    if let code = currentEntry.failureCode, !code.isEmpty {
                        ValueRow(label: "Code", value: code.replacingOccurrences(of: "_", with: " ").capitalized)
                    }
                    if let reason = currentEntry.failureReason, !reason.isEmpty {
                        Text(reason).foregroundStyle(.red)
                    }
                }
            }

            Section("Reference") {
                ValueRow(label: "Activity ID", value: currentEntry.id, copyable: true)
            }
        }
        .navigationTitle("Activity Details")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("activity.detail")
        .sheet(isPresented: $showingInvoiceQR) {
            LightningInvoiceQRCodeSheet(
                invoice: currentEntry.request?.lightningInvoice ?? "",
                amountSat: currentEntry.amountSat
            )
        }
    }

}

private struct LightningInvoiceQRCodeSheet: View {
    @Environment(\.presentationMode) private var presentationMode
    let invoice: String
    let amountSat: Int64
    @State private var showingShare = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 22) {
                    QRCodeView(value: invoice)
                        .frame(width: 270, height: 270)
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityLabel("Pending Lightning invoice QR code")

                    VStack(spacing: 6) {
                        Text("Pending Lightning invoice")
                            .font(.headline)
                        if amountSat > 0 {
                            Text(WalletFormatting.sats(amountSat))
                                .font(.title3.bold())
                        }
                        Text("This is the original invoice. Sharing it does not create a new payment request.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Text(invoice)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .privacySensitive()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12)
                        )

                    HStack(spacing: 14) {
                        Button {
                            UIPasteboard.general.string = invoice
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            showingShare = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Receive Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingShare) {
                ShareSheet(items: [invoice])
            }
        }
        .navigationViewStyle(.stack)
    }
}
