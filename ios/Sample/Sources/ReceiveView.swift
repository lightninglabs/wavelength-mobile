import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import WalletKit

private enum ReceiveRail: String, CaseIterable, Identifiable {
    case lightning = "Lightning"
    case onchain = "On-chain"
    var id: String { rawValue }
}

struct ReceiveView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rail: ReceiveRail = .lightning
    @State private var amount = ""
    @FocusState private var amountFocused: Bool
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
    private var showsRequest: Bool {
        currentEntry?.isAwaitingIncomingPayment ?? true
    }

    var body: some View {
        NavigationView {
            WalletPage {
                if request.isEmpty { requestForm.disabled(isLoading) } else { paymentRequest }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if request.isEmpty {
                    createButton
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .background(WalletTheme.background)
                }
            }
            .navigationTitle("Receive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .interactiveDismissDisabled(isLoading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsRequest)
            .sheet(isPresented: Binding(get: { errorMessage != nil },
                                                  set: { if !$0 { errorMessage = nil } })) {
                PaymentErrorSheet(title: "Receive", message: errorMessage ?? "")
            }
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
            amountEntry
            DisclosureGroup("Note") {
                TextField("Optional", text: $memo).accessibilityIdentifier("receive.memo").padding(.top, 12)
            }
        }
        if !store.operatorAvailable {
            Text("Configure a connection in Settings.").foregroundStyle(WalletTheme.secondary)
        }
    }

    /// Size the editor to its digits so the caret and unit stay together.
    private var amountEntry: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(amount.isEmpty ? "0" : amount)
                .lineLimit(1)
                .hidden()
                .padding(.horizontal, 2)
                .overlay {
                    TextField("0", text: $amount)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .focused($amountFocused)
                        .accessibilityLabel("Amount in satoshis")
                        .accessibilityIdentifier("receive.amount")
                }
                .font(.system(size: 54, weight: .regular))
                .privacySensitive()
            Text("sats")
                .font(.title2)
                .foregroundStyle(WalletTheme.secondary)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .contentShape(Rectangle())
        .onTapGesture { amountFocused = true }
        .onAppear { amountFocused = store.offchainAvailable }
    }

    /// Keep the primary action reachable above the active keyboard.
    private var createButton: some View {
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
        if !showsRequest, let entry = currentEntry {
            WalletAmount(amount: entry.amountSat)
            if !entry.note.isEmpty { Text(entry.note).foregroundStyle(WalletTheme.secondary) }
            WalletStatus(text: entry.displayStatus, pending: entry.showsActivityProgress,
                         complete: entry.status == "complete", failed: entry.status == "failed")
            if let date = WalletFormatting.date(entry.createdAt) {
                Text(date).font(.subheadline).foregroundStyle(WalletTheme.secondary)
            }
            if let reason = entry.failureReason, !reason.isEmpty {
                Text(PaymentFailure.message(reason)).font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
        } else {
            VStack(spacing: 12) {
                if rail == .lightning, let sats = Int64(amount), sats > 0 {
                    WalletAmount(amount: sats)
                }
                WalletStatus(text: "Waiting for payment")
                    .foregroundStyle(WalletTheme.secondary)
            }
            .frame(maxWidth: .infinity)
            RequestQRCodeCard(value: request)
            if rail == .onchain {
                // Give the selectable view the wrapped height even on iOS 15,
                // where UIViewRepresentable has no sizeThatFits proposal.
                Text(verbatim: request)
                    .font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .frame(maxWidth: .infinity)
                    .overlay { BitcoinAddressText(address: request) }
                    .privacySensitive()
            }
            requestActions
        }
        if rail == .lightning || !showsRequest {
            DisclosureGroup("Details", isExpanded: $details) {
                VStack(alignment: .leading, spacing: 20) {
                    if !showsRequest { requestActions }
                    requestValue.font(.system(.caption, design: .monospaced))
                    if !showsRequest, let entry = currentEntry {
                        if let reason = entry.failureReason,
                           let detail = PaymentFailure.technicalDetails(reason) {
                            ValueRow(label: "Error", value: detail, copyable: true)
                        }
                        NavigationLink(destination: ActivityDetailView(entry: entry)) { Text("Activity") }
                    }
                }.padding(.vertical, 12)
            }
        }
        if !showsRequest {
            Button("Done") { presentationMode.wrappedValue.dismiss() }
                .buttonStyle(WalletButtonStyle())
        }
    }

    /// Copy and share the same complete payload encoded in the QR code.
    private var requestActions: some View {
        HStack(spacing: 12) {
            Button { UIPasteboard.general.string = request } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("receive.copy")
            Button { showingShare = true } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .buttonStyle(WalletButtonStyle(secondary: true))
    }

    private var requestValue: some View {
        Text(request)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled).privacySensitive()
            .accessibilityIdentifier("receive.request")
    }

    private func createRequest() {
        guard !isLoading else { return }
        amountFocused = false
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

/// Wrap addresses between characters. Prose hyphenation can display a dash
/// that is absent from both the QR code and the selected text.
private struct BitcoinAddressText: UIViewRepresentable {
    /// The complete address copied, shared and encoded in the QR.
    let address: String

    /// Use native selection and wrap without adding characters to the address.
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.textAlignment = .center
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 17, weight: .regular)
        )
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(WalletTheme.foreground)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "receive.request"
        return view
    }

    /// Preserve the selection across unrelated SwiftUI updates.
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != address { view.text = address }
    }
}

/// Shows only the saved payload, with a four-module quiet zone in the image.
struct RequestQRCodeCard: View {
    let value: String

    var body: some View {
        QRCodeView(value: value, fullQuietZone: true)
        .aspectRatio(1, contentMode: .fit)
        .padding(4)
        .frame(maxWidth: 420)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Payment request QR code")
        .accessibilityIdentifier("request.qr")
        .privacySensitive()
    }
}

struct QRCodeView: View {
    let value: String
    var fullQuietZone = false

    var body: some View {
        if let image = QRCodeGenerator.image(for: value, fullQuietZone: fullQuietZone) {
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
    static func image(for value: String, fullQuietZone: Bool) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Core Image supplies one clear module. Payment requests add three
        // more in module space, so even short addresses retain four in total.
        let symbol: CIImage
        if fullQuietZone {
            let background = CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -3, dy: -3))
            symbol = output.composited(over: background)
        } else {
            symbol = output
        }
        let transformed = symbol.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
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
