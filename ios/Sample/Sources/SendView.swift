import SwiftUI
import WalletKit

struct SendView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var destination = ""
    @State private var amount = ""
    @State private var note = ""
    @State private var maxFee = ""
    @State private var sweepAll = false
    @State private var quote: PrepareSendResult?
    @State private var sentResult: SendResult?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showsScanner = false
    @State private var showOptions = false
    @State private var showDetails = false

    private var normalizedDestination: String { PaymentRequestParser.normalizedDestination(from: destination) }
    private var isLightning: Bool { normalizedDestination.lowercased().hasPrefix("ln") }
    private var resultEntry: Entry? {
        guard let result = sentResult else { return nil }
        return store.activity.first { $0.id == result.entry.id } ?? result.entry
    }
    private var stage: String {
        if resultEntry != nil { return "result" }
        if store.pendingDispatch != nil { return "checking" }
        return quote == nil ? "input" : "review"
    }

    var body: some View {
        NavigationView {
            WalletPage {
                if let entry = resultEntry {
                    WalletAmount(amount: abs(entry.amountSat))
                    Text(entry.note.isEmpty ? "Payment" : entry.note).foregroundStyle(WalletTheme.secondary)
                    WalletStatus(text: entry.displayStatus, pending: entry.status == "pending",
                                 complete: entry.status == "complete", failed: entry.status == "failed")
                    NavigationLink(destination: ActivityDetailView(entry: entry)) { Text("Details") }
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                        .buttonStyle(WalletButtonStyle())
                } else if let pending = store.pendingDispatch {
                    WalletAmount(amount: pending.amountSat)
                    WalletStatus(text: "Checking payment", pending: true)
                    Text("Check Activity before sending again.").foregroundStyle(WalletTheme.secondary)
                    DisclosureGroup("Details", isExpanded: $showDetails) {
                        ValueRow(label: "Payment reference", value: pending.intentID, copyable: true)
                        if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(WalletTheme.secondary) }
                    }
                    Button("Check status") { Task { await store.refresh() } }
                        .buttonStyle(WalletButtonStyle())
                } else if let quote {
                    review(quote)
                } else {
                    input
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: stage)
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .interactiveDismissDisabled(isLoading)
            .sheet(isPresented: $showsScanner) {
                PaymentQRCodeScannerView { destination = $0 }
            }
            .alert("Payment", isPresented: Binding(get: { errorMessage != nil && store.pendingDispatch == nil },
                                                   set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .onChange(of: resultEntry?.status) { status in
                if status == "complete" { WalletFeedback.completed() }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var input: some View {
        Group {
            WalletField(title: "Invoice or Bitcoin address") {
                TextField("Scan or paste", text: $destination)
                    .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                    .accessibilityIdentifier("send.destination")
            }
            HStack {
                Button { showsScanner = true } label: { Label("Scan", systemImage: "viewfinder") }
                    .accessibilityIdentifier("send.scan")
                Spacer()
                if #available(iOS 16.0, *) {
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first { destination = value }
                    }
                    .accessibilityIdentifier("send.paste")
                } else {
                    Button("Paste") { destination = UIPasteboard.general.string ?? "" }
                }
            }
            if !isLightning {
                WalletField(title: "Amount") {
                    HStack {
                        TextField("0", text: $amount).keyboardType(.numberPad)
                            .accessibilityIdentifier("send.amount")
                        Text("sats").foregroundStyle(WalletTheme.secondary)
                    }
                }
                Toggle("Use available balance", isOn: $sweepAll)
            }
            DisclosureGroup("Options", isExpanded: $showOptions) {
                VStack(spacing: 18) {
                    WalletField(title: "Note") { TextField("Optional", text: $note) }
                    if isLightning {
                        WalletField(title: "Maximum fee (sats)") {
                            TextField("Automatic", text: $maxFee).keyboardType(.numberPad)
                        }
                    }
                }.padding(.top, 18)
            }
            if !store.operatorAvailable || (isLightning && !store.offchainAvailable) {
                Text("Configure a connection in Settings.").foregroundStyle(WalletTheme.secondary)
            }
            Button(action: prepare) {
                if isLoading { ProgressView() } else { Text("Review") }
            }
            .buttonStyle(WalletButtonStyle())
            .disabled(isLoading || !store.isReady || !store.operatorAvailable ||
                      (isLightning && !store.offchainAvailable) || normalizedDestination.isEmpty ||
                      (!isLightning && !sweepAll && (Int64(amount) ?? 0) <= 0))
            .accessibilityIdentifier("send.review")
        }
    }

    @ViewBuilder private func review(_ prepared: PrepareSendResult) -> some View {
        WalletAmount(amount: prepared.amountSat)
        Text(prepared.invoiceDescription?.isEmpty == false ? prepared.invoiceDescription! : prepared.destinationSummary)
            .foregroundStyle(WalletTheme.secondary).lineLimit(2)
        VStack(spacing: 18) {
            WalletDivider()
            receiptLine("Fee", prepared.feeKnown ? WalletFormatting.sats(prepared.expectedFeeSat) : "Unavailable")
            if let credit = prepared.creditPreview {
                if credit.creditAppliedSat > 0 {
                    receiptLine("Credit used", WalletFormatting.sats(credit.creditAppliedSat))
                }
                if credit.creditTopupSat > 0 {
                    receiptLine("Credit top-up", WalletFormatting.sats(credit.creditTopupSat))
                }
                Text("Provider-held credit").font(.caption).foregroundStyle(WalletTheme.secondary)
            }
            if (prepared.totalOutflowKnown ?? prepared.feeKnown),
               prepared.creditPreview == nil || prepared.expectedTotalOutflowSat > 0 {
                receiptLine(prepared.creditPreview == nil ? "Total" : "Balance debit",
                            WalletFormatting.sats(prepared.expectedTotalOutflowSat))
            }
            WalletDivider()
        }
        DisclosureGroup("Details", isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 16) {
                ValueRow(label: "Destination", value: prepared.destinationSummary, copyable: true)
                ValueRow(label: "Network", value: prepared.rail)
                if !note.isEmpty { ValueRow(label: "Note", value: note) }
            }.padding(.top, 16)
        }
        if !prepared.warning.isEmpty {
            Text(prepared.warning).font(.footnote).foregroundStyle(WalletTheme.secondary)
        }
        Button { send(prepared) } label: {
            if isLoading { ProgressView() } else { Text("Confirm") }
        }
        .buttonStyle(WalletButtonStyle()).disabled(isLoading)
        .accessibilityIdentifier("send.confirm")
        Button("Edit") { quote = nil }.disabled(isLoading)
    }

    private func receiptLine(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(WalletTheme.secondary); Spacer(); Text(value).monospacedDigit() }
    }

    private func prepare() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                quote = try await store.prepareSend(destination: normalizedDestination,
                    amountSat: Int64(amount) ?? 0, note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                    maxFeeSat: Int64(maxFee) ?? 0, sweepAll: sweepAll)
            } catch { errorMessage = error.walletMessage }
        }
    }

    private func send(_ prepared: PrepareSendResult) {
        guard !isLoading else { return }
        isLoading = true
        quote = nil
        Task {
            defer { isLoading = false }
            do { sentResult = try await store.sendPrepared(prepared) }
            catch { errorMessage = error.walletMessage }
        }
    }
}
