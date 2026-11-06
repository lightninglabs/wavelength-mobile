import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import WalletKit

private enum ReceiveRail: String, CaseIterable, Identifiable {
    case lightning = "Lightning"
    case onchain = "Bitcoin address"
    var id: String { rawValue }
}

struct ReceiveView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rail: ReceiveRail = .lightning
    @State private var amount = ""
    @State private var memo = ""
    @State private var request = ""
    @State private var initialEntry: Entry?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingShare = false
    @State private var details = false

    init(existingEntry: Entry? = nil) {
        _initialEntry = State(initialValue: existingEntry)
        _request = State(initialValue: existingEntry?.request?.lightningInvoice ?? "")
        _amount = State(initialValue: existingEntry.map { String($0.amountSat) } ?? "")
    }

    private var currentEntry: Entry? {
        store.activity.first { entry in
            if let initialEntry, entry.id == initialEntry.id { return true }
            return !request.isEmpty && entry.request?.onchainAddress == request
        } ?? initialEntry
    }
    private var paymentDetected: Bool {
        guard let currentEntry else { return false }
        return !currentEntry.isAwaitingIncomingPayment
    }

    var body: some View {
        NavigationView {
            WalletPage {
                if request.isEmpty { requestForm } else { paymentRequest }
            }
            .navigationTitle("Receive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .interactiveDismissDisabled(isLoading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: paymentDetected)
            .alert("Receive", isPresented: Binding(get: { errorMessage != nil },
                                                  set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .sheet(isPresented: $showingShare) { ShareSheet(items: [request]) }
            .onAppear { if request.isEmpty && !store.offchainAvailable { rail = .onchain } }
            .onChange(of: currentEntry?.status) { status in
                if status == "complete" { WalletFeedback.completed() }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder private var requestForm: some View {
        Picker("Receive using", selection: $rail) {
            ForEach(ReceiveRail.allCases) { option in
                Text(option.rawValue).tag(option)
                    .disabled(option == .lightning && !store.offchainAvailable)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("receive.rail")
        if rail == .lightning {
            WalletField(title: "Amount") {
                HStack {
                    TextField("0", text: $amount).keyboardType(.numberPad)
                        .accessibilityIdentifier("receive.amount")
                    Text("sats").foregroundStyle(WalletTheme.secondary)
                }
            }
            DisclosureGroup("Note") {
                TextField("Optional", text: $memo).accessibilityIdentifier("receive.memo").padding(.top, 12)
            }
        }
        if !store.operatorAvailable {
            Text("Configure a connection in Settings.").foregroundStyle(WalletTheme.secondary)
        }
        Button(action: createRequest) {
            if isLoading { ProgressView() }
            else { Text(rail == .lightning ? "Create request" : "Create address") }
        }
        .buttonStyle(WalletButtonStyle())
        .disabled(isLoading || !store.isReady || !store.operatorAvailable ||
                  (rail == .lightning && ((Int64(amount) ?? 0) <= 0 || !store.offchainAvailable)))
        .accessibilityIdentifier("receive.create")
    }

    @ViewBuilder private var paymentRequest: some View {
        if paymentDetected, let entry = currentEntry {
            WalletAmount(amount: entry.amountSat)
            if !entry.note.isEmpty { Text(entry.note).foregroundStyle(WalletTheme.secondary) }
            WalletStatus(text: entry.displayStatus, pending: entry.status == "pending",
                         complete: entry.status == "complete", failed: entry.status == "failed")
            if let date = WalletFormatting.date(entry.createdAt) {
                Text(date).font(.subheadline).foregroundStyle(WalletTheme.secondary)
            }
            if let reason = entry.failureReason, !reason.isEmpty {
                Text(reason).font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            DisclosureGroup("Details", isExpanded: $details) {
                requestContent
                NavigationLink(destination: ActivityDetailView(entry: entry)) { Text("Activity") }
            }
        } else {
            if rail == .lightning, (Int64(amount) ?? 0) > 0 {
                WalletAmount(amount: Int64(amount) ?? 0)
            }
            QRCodeView(value: request)
                .frame(maxWidth: 290, maxHeight: 290)
                .aspectRatio(1, contentMode: .fit)
                .padding(18)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Payment request QR code")
            requestContent
            WalletStatus(text: "Waiting for payment")
                .foregroundStyle(WalletTheme.secondary)
        }
        if paymentDetected {
            Button("Done") { presentationMode.wrappedValue.dismiss() }
                .buttonStyle(WalletButtonStyle())
        }
    }

    private var requestContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 20) {
                Button { UIPasteboard.general.string = request } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("receive.copy")
                Button { showingShare = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
            }
            if paymentDetected { requestValue } else {
                DisclosureGroup("Details", isExpanded: $details) { requestValue.padding(.top, 12) }
            }
        }.padding(.vertical, 12)
    }

    private var requestValue: some View {
        Text(request)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled).privacySensitive()
            .accessibilityIdentifier("receive.request")
    }

    private func createRequest() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                if rail == .lightning {
                    let result = try await store.receiveLightning(amountSat: Int64(amount) ?? 0,
                        memo: memo.trimmingCharacters(in: .whitespacesAndNewlines))
                    initialEntry = result.entry
                    request = result.invoice
                } else {
                    request = try await store.newDepositAddress(amountHintSat: 0).address
                }
            } catch { errorMessage = error.walletMessage }
        }
    }
}

struct QRCodeView: View {
    let value: String

    var body: some View {
        if let image = QRCodeGenerator.image(for: value) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.black)
        }
    }
}

private enum QRCodeGenerator {
    static func image(for value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
