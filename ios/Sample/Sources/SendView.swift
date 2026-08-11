import SwiftUI
import WalletKit

struct SendView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.presentationMode) private var presentationMode

    @State private var destination = ""
    @State private var amount = ""
    @State private var note = ""
    @State private var maxFee = ""
    @State private var quote: PrepareSendResult?
    @State private var sentResult: SendResult?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showsScanner = false

    private var normalizedDestination: String {
        PaymentRequestParser.normalizedDestination(from: destination)
    }

    private var isLightning: Bool { normalizedDestination.lowercased().hasPrefix("ln") }
    private var amountSat: Int64 { Int64(amount) ?? 0 }
    private var maxFeeSat: Int64 { Int64(maxFee) ?? 0 }

    var body: some View {
        NavigationView {
            Form {
                if let sentResult {
                    successSection(sentResult)
                } else if let quote {
                    reviewSections(quote)
                } else {
                    inputSections
                }
            }
            .navigationTitle(sentResult == nil ? "Send Bitcoin" : "Payment Sent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sentResult == nil ? "Cancel" : "Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .alert("Couldn’t Send", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: destination) { _ in quote = nil }
            .onChange(of: amount) { _ in quote = nil }
            .onChange(of: maxFee) { _ in quote = nil }
            .sheet(isPresented: $showsScanner) {
                PaymentQRCodeScannerView { scannedDestination in
                    destination = scannedDestination
                }
            }
        }
    }

    @ViewBuilder
    private var inputSections: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if destination.isEmpty {
                    Text("Lightning invoice or Bitcoin address")
                        .foregroundStyle(Color(.placeholderText))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                }
                TextEditor(text: $destination)
                    .frame(minHeight: 90)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
            HStack {
                Button {
                    showsScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "viewfinder")
                }
                .accessibilityIdentifier("send.scan")

                Spacer()

                Button {
                    if let value = UIPasteboard.general.string { destination = value }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
            }
        } header: {
            Text("Pay to")
        } footer: {
            Text(destinationHint)
        }

        if !isLightning {
            Section("Amount") {
                HStack {
                    TextField("0", text: $amount)
                        .keyboardType(.numberPad)
                    Text("sats").foregroundStyle(.secondary)
                }
            }
        }

        Section("Optional") {
            TextField("Note", text: $note)
            if isLightning {
                HStack {
                    TextField("Maximum fee", text: $maxFee)
                        .keyboardType(.numberPad)
                    Text("sats").foregroundStyle(.secondary)
                }
            }
        }

        if !store.offchainAvailable {
            Section {
                Label(
                    "\(store.network.title) sending requires operator and swap endpoints in Settings.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        }

        Section {
            Button {
                prepare()
            } label: {
                HStack {
                    Spacer()
                    if isLoading { ProgressView().padding(.trailing, 6) }
                    Text("Review Payment")
                    Spacer()
                }
            }
            .disabled(!canPrepare || isLoading)
        } footer: {
            Text("Preparing validates the destination and quotes fees. It does not move funds.")
        }
    }

    @ViewBuilder
    private func reviewSections(_ quote: PrepareSendResult) -> some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: isLightning ? "bolt.fill" : "bitcoinsign")
                    .font(.title2.bold())
                    .foregroundStyle(.orange)
                    .frame(width: 54, height: 54)
                    .background(Color.orange.opacity(0.12), in: Circle())
                Text(WalletFormatting.sats(quote.amountSat))
                    .font(.title2.bold())
                Text(quote.rail.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }

        Section("Quote") {
            ValueRow(label: "Amount", value: WalletFormatting.sats(quote.amountSat))
            ValueRow(
                label: "Expected fee",
                value: quote.feeKnown ? WalletFormatting.sats(quote.expectedFeeSat) : "Finalized during payment"
            )
            if quote.totalOutflowKnown ?? quote.feeKnown {
                ValueRow(label: "Expected total", value: WalletFormatting.sats(quote.expectedTotalOutflowSat))
            }
            ValueRow(label: "Destination", value: quote.destinationSummary, copyable: true)
            if let description = quote.invoiceDescription, !description.isEmpty {
                ValueRow(label: "Invoice note", value: description)
            }
            if !note.isEmpty { ValueRow(label: "Your note", value: note) }
        }

        if !quote.warning.isEmpty {
            Section {
                Label(quote.warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }

        Section {
            Button(role: .destructive) {
                send(quote)
            } label: {
                HStack {
                    Spacer()
                    if isLoading { ProgressView().padding(.trailing, 6) }
                    Text("Confirm and Send")
                    Spacer()
                }
            }
            .disabled(isLoading)

            Button("Edit Payment") { self.quote = nil }
                .disabled(isLoading)
        } footer: {
            Text("This quote is single-use. Wavelength will never automatically retry a failed dispatch with a new payment identity.")
        }
    }

    private func successSection(_ result: SendResult) -> some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(.green)
                Text("Payment submitted").font(.title2.bold())
                Text(WalletFormatting.sats(result.actualAmountSat))
                    .font(.title3.weight(.semibold))
                Text("Track settlement in Activity.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var destinationHint: String {
        if destination.isEmpty { return "Scan or paste a BOLT 11 invoice or a network-matching on-chain address." }
        return isLightning ? "Lightning invoice detected" : "On-chain Bitcoin address detected"
    }

    private var canPrepare: Bool {
        guard store.isReady, store.offchainAvailable,
              !normalizedDestination.isEmpty else { return false }
        if isLightning { return true }
        return amountSat > 0
    }

    private func prepare() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                quote = try await store.prepareSend(
                    destination: normalizedDestination,
                    amountSat: amountSat,
                    note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                    maxFeeSat: maxFeeSat
                )
            } catch {
                errorMessage = error.walletMessage
            }
        }
    }

    private func send(_ prepared: PrepareSendResult) {
        isLoading = true
        // Consume the local quote before dispatch. The intent is single-use;
        // an error requires an explicit fresh prepare rather than replaying it.
        quote = nil
        Task {
            defer { isLoading = false }
            do {
                sentResult = try await store.sendPrepared(intentID: prepared.sendIntentID)
            } catch {
                errorMessage = "The payment result is not confirmed. Review Activity, then prepare a fresh quote if you still need to pay. \(error.walletMessage)"
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
