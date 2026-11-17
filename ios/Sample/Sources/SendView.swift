import SwiftUI
import WalletKit

struct SendView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var destination = ""
    @State private var amount = ""
    @State private var invoice: InvoiceDetails?
    @State private var invoiceError: String?
    @FocusState private var amountFocused: Bool
    @State private var note = ""
    @State private var maxFee = ""
    @State private var sweepAll = false
    @State private var maximumQuote: PrepareSendResult?
    @State private var maximumDraft: SendDraft?
    @State private var maximumRequestID = UUID()
    @State private var calculatingMaximum = false
    @State private var maximumError: String?
    @State private var quote: PrepareSendResult?
    @State private var sentResult: SendResult?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showsScanner = false
    @State private var showOptions = false
    @State private var showDetails = false
    @State private var confirmsSeparatePayment = false

    private var normalizedDestination: String { PaymentRequestParser.normalizedDestination(from: destination) }
    private var isLightning: Bool { normalizedDestination.lowercased().hasPrefix("ln") }
    private var requiresAmount: Bool { !isLightning || invoice?.amountSat == nil }
    private var canPrepare: Bool {
        store.isReady && store.operatorAvailable && (!isLightning || (store.offchainAvailable && invoice != nil))
    }
    private var maximumRequest: SendDraft? {
        guard canPrepare, sweepAll, requiresAmount, !normalizedDestination.isEmpty,
              !isLoading, store.pendingDispatch == nil, sentResult == nil else { return nil }
        return draft
    }
    private var enteredAmount: Int64? { SendAmount.satoshis(amount) }
    private var currentMaximum: PrepareSendResult? { maximumDraft == draft ? maximumQuote : nil }
    private var draft: SendDraft {
        SendDraft(destination: normalizedDestination, amount: sweepAll ? "" : amount, note: note,
                  maxFee: maxFee, sweepAll: sweepAll, network: store.network.rawValue)
    }
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
                    if let date = WalletFormatting.date(entry.createdAt) {
                        Text(date).font(.subheadline).foregroundStyle(WalletTheme.secondary)
                    }
                    NavigationLink(destination: ActivityDetailView(entry: entry)) { Text("Details") }
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                        .buttonStyle(WalletButtonStyle())
                } else if let pending = store.pendingDispatch {
                    if pending.isBalanceSweep == true && pending.sweepRecipientAmountSat == nil {
                        Text("Balance debit").font(.subheadline).foregroundStyle(WalletTheme.secondary)
                    }
                    WalletAmount(amount: pending.sweepRecipientAmountSat ?? pending.amountSat)
                    WalletStatus(text: "Checking payment", pending: true)
                    Text("Check Activity before sending again.").foregroundStyle(WalletTheme.secondary)
                    DisclosureGroup("Details", isExpanded: $showDetails) {
                        ValueRow(label: "Payment reference", value: pending.intentID, copyable: true)
                        if let message = pending.error ?? errorMessage, !message.isEmpty {
                            ValueRow(label: "Error", value: message, copyable: true)
                        }
                    }
                    Button("Check status") { Task { await store.refresh() } }
                        .buttonStyle(WalletButtonStyle())
                    if pending.canStartSeparatePayment {
                        Button("Review another payment") { confirmsSeparatePayment = true }
                            .disabled(!store.canChangeNetwork)
                    }
                } else if let quote {
                    review(quote)
                } else {
                    input.disabled(isLoading)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: stage)
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { presentationMode.wrappedValue.dismiss() }.disabled(isLoading)
                }
            }
            .interactiveDismissDisabled(isLoading)
            .sheet(isPresented: $showsScanner) {
                PaymentQRCodeScannerView { destination = $0 }
            }
            .sheet(isPresented: Binding(get: { errorMessage != nil && store.pendingDispatch == nil },
                                                   set: { if !$0 { errorMessage = nil } })) {
                PaymentErrorSheet(title: "Payment", message: errorMessage ?? "")
            }
            .confirmationDialog("Original payment is unconfirmed", isPresented: $confirmsSeparatePayment,
                                titleVisibility: .visible) {
                Button("Start separate payment", role: .destructive) {
                    store.startSeparatePaymentAfterChecking()
                    destination = ""; amount = ""; note = ""; quote = nil; errorMessage = nil
                }
                Button("Keep checking", role: .cancel) {}
            } message: {
                Text("It may still complete. Check Activity and the recipient before starting a separate payment. The original reference stays in Recovery → Payment checks.")
            }
            .task(id: normalizedDestination + ":" + store.network.rawValue) { await inspectInvoice() }
            .task(id: maximumRequest) { await calculateMaximum() }
            .onChange(of: draft) { _ in quote = nil }
            .onChange(of: sweepAll) { enabled in
                if enabled { amountFocused = false }
                else { maximumQuote = nil; maximumError = nil }
            }
            .onChange(of: resultEntry?.status) { status in
                if status == "complete" { WalletFeedback.completed() }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var input: some View {
        Group {
            if let invoice {
                WalletField(title: "Invoice") {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.fill")
                        Text(invoice.description.isEmpty ? "Lightning payment" : invoice.description)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Button("Change") { destination = ""; amount = "" }
                            .font(.subheadline).foregroundStyle(WalletTheme.secondary)
                            .accessibilityIdentifier("send.changeInvoice")
                    }
                }
            } else {
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
                if let invoiceError {
                    Text(PaymentFailure.message(invoiceError)).font(.footnote).foregroundStyle(WalletTheme.secondary)
                        .accessibilityIdentifier("send.invoiceError")
                }
            }
            if let signedAmount = invoice?.amountSat {
                WalletAmount(amount: signedAmount)
            } else if !isLightning || invoice != nil {
                VStack(alignment: .leading, spacing: 10) {
                    if sweepAll {
                        if calculatingMaximum {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Calculating…").foregroundStyle(WalletTheme.secondary)
                            }.frame(minHeight: 65)
                                .accessibilityIdentifier("send.calculatingMaximum")
                        } else if let currentMaximum {
                            if showsSweepDebit(currentMaximum) {
                                Text("Balance debit").font(.subheadline).foregroundStyle(WalletTheme.secondary)
                            }
                            WalletAmount(amount: displayAmount(currentMaximum))
                                .accessibilityIdentifier("send.maximumAmount")
                        } else if normalizedDestination.isEmpty {
                            Text("Add a destination to calculate the amount.")
                                .font(.subheadline).foregroundStyle(WalletTheme.secondary)
                        }
                        if let maximumError {
                            Text(PaymentFailure.message(maximumError))
                                .font(.footnote).foregroundStyle(WalletTheme.secondary)
                            HStack(spacing: 20) {
                                Button("Try again") { Task { await calculateMaximum() } }
                                    .disabled(calculatingMaximum)
                                Button("Details") { errorMessage = maximumError }
                            }
                        }
                    } else {
                        Text("Amount").font(.subheadline).foregroundStyle(WalletTheme.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            TextField("0", text: $amount).keyboardType(.numberPad)
                                .font(.system(size: 54, weight: .regular))
                                .focused($amountFocused)
                                .accessibilityIdentifier("send.amount")
                            Text("sats").font(.title2).foregroundStyle(WalletTheme.secondary)
                        }
                    }
                    Toggle("Use available balance", isOn: $sweepAll)
                        .accessibilityIdentifier("send.useAvailableBalance")
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: sweepAll)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: calculatingMaximum)
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
            .disabled(isLoading || !canPrepare || normalizedDestination.isEmpty ||
                      (sweepAll && (calculatingMaximum || currentMaximum == nil)) ||
                      (requiresAmount && !sweepAll && enteredAmount == nil))
            .accessibilityIdentifier("send.review")
        }
    }

    @ViewBuilder private func review(_ prepared: PrepareSendResult) -> some View {
        if showsSweepDebit(prepared) {
            Text("Balance debit").font(.subheadline).foregroundStyle(WalletTheme.secondary)
        }
        WalletAmount(amount: displayAmount(prepared))
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

    private func displayAmount(_ prepared: PrepareSendResult) -> Int64 {
        // The sweep preview reports the selected total. Its fee comes out of
        // the recipient's output, while Total still shows the full debit.
        if sweepAll, prepared.rail == "onchain", prepared.feeKnown {
            return prepared.amountSat - prepared.expectedFeeSat
        }
        return prepared.amountSat
    }

    private func showsSweepDebit(_ prepared: PrepareSendResult) -> Bool {
        sweepAll && prepared.rail == "onchain" && !prepared.feeKnown
    }

    private func prepare() {
        guard !isLoading else { return }
        if sweepAll {
            guard !calculatingMaximum, let currentMaximum else { return }
            quote = currentMaximum
            return
        }
        let request = draft
        let paymentAmount = requiresAmount ? (enteredAmount ?? 0) : 0
        guard !requiresAmount || paymentAmount > 0 else { return }
        amountFocused = false
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let prepared = try await store.prepareSend(destination: request.destination,
                    amountSat: paymentAmount, note: request.note.trimmingCharacters(in: .whitespacesAndNewlines),
                    maxFeeSat: Int64(request.maxFee) ?? 0)
                // An edited draft must never display or dispatch the old quote.
                guard request == draft else { return }
                quote = prepared
            } catch {
                errorMessage = SendAmount.prepareError(error.walletMessage,
                    amountlessInvoice: isLightning && invoice?.amountSat == nil)
            }
        }
    }

    private func calculateMaximum() async {
        let requestID = UUID()
        maximumRequestID = requestID
        maximumQuote = nil
        maximumDraft = nil
        maximumError = nil
        calculatingMaximum = false
        guard let request = maximumRequest else { return }
        let lightning = isLightning
        calculatingMaximum = true
        defer {
            if maximumRequestID == requestID { calculatingMaximum = false }
        }
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            let prepared = try await store.prepareSend(
                destination: request.destination, amountSat: 0,
                note: request.note.trimmingCharacters(in: .whitespacesAndNewlines),
                maxFeeSat: Int64(request.maxFee) ?? 0,
                sweepAll: !lightning, maxAmount: lightning
            )
            try Task.checkCancellation()
            guard maximumRequestID == requestID, request == maximumRequest else { return }
            maximumQuote = prepared
            maximumDraft = request
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, maximumRequestID == requestID, request == maximumRequest else { return }
            maximumError = error.walletMessage
        }
    }

    private func inspectInvoice() async {
        invoice = nil
        invoiceError = nil
        guard isLightning else { return }
        let destination = normalizedDestination
        let network = store.network
        do {
            try await Task.sleep(nanoseconds: 200_000_000)
            let decoded = try await store.decodeInvoice(destination)
            try Task.checkCancellation()
            guard destination == normalizedDestination && network == store.network else { return }
            invoice = decoded
            amount = ""
            sweepAll = false
            amountFocused = decoded.amountSat == nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled && destination == normalizedDestination && network == store.network else { return }
            invoiceError = error.walletMessage
        }
    }

    private func send(_ prepared: PrepareSendResult) {
        guard !isLoading else { return }
        let isBalanceSweep = sweepAll && prepared.rail == "onchain"
        isLoading = true
        quote = nil
        Task {
            defer { isLoading = false }
            do { sentResult = try await store.sendPrepared(prepared, isBalanceSweep: isBalanceSweep) }
            catch {
                errorMessage = error.walletMessage
                // Send consumes its intent even on failure. A Max retry must
                // calculate a new preview instead of reusing that token.
                if sweepAll {
                    maximumQuote = nil
                    maximumDraft = nil
                }
            }
        }
    }
}
