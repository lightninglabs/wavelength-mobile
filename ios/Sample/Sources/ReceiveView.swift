import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

private enum ReceiveRail: String, CaseIterable, Identifiable {
    case lightning = "Lightning"
    case onchain = "On-chain"
    var id: String { rawValue }
}

struct ReceiveView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.presentationMode) private var presentationMode
    @State private var rail: ReceiveRail = .lightning
    @State private var amount = ""
    @State private var memo = ""
    @State private var request = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingShare = false

    private var amountSat: Int64 { Int64(amount) ?? 0 }

    var body: some View {
        NavigationView {
            Form {
                if request.isEmpty {
                    requestForm
                } else {
                    paymentRequest
                }
            }
            .navigationTitle("Receive Bitcoin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(request.isEmpty ? "Cancel" : "Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .alert("Couldn’t Create Request", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showingShare) {
                ShareSheet(items: [request])
            }
            .onAppear {
                if !store.offchainAvailable { rail = .onchain }
            }
        }
    }

    @ViewBuilder
    private var requestForm: some View {
        Section {
            Picker("Receive using", selection: $rail) {
                ForEach(ReceiveRail.allCases) { option in
                    Text(option.rawValue)
                        .tag(option)
                        .disabled(option == .lightning && !store.offchainAvailable)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("receive.rail")
        } footer: {
            if !store.operatorAvailable {
                Text("\(store.network.title) receive requires a trusted Ark operator endpoint in Settings. Esplora syncs the chain, but it cannot create a Wavelength boarding address by itself.")
            } else if !store.offchainAvailable {
                Text("\(store.network.title) Lightning additionally requires a swap endpoint in Settings. On-chain boarding receive remains available.")
            }
        }

        Section("Amount") {
            HStack {
                TextField(rail == .lightning ? "Required" : "Optional hint", text: $amount)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("receive.amount")
                Text("sats").foregroundStyle(.secondary)
            }
        }

        if rail == .lightning {
            Section("Optional") {
                TextField("Memo", text: $memo)
            }
        }

        Section {
            Button {
                createRequest()
            } label: {
                HStack {
                    Spacer()
                    if isLoading { ProgressView().padding(.trailing, 6) }
                    Text(rail == .lightning ? "Create Invoice" : "Create Address")
                    Spacer()
                }
            }
            .disabled(!canCreate || isLoading)
            .accessibilityIdentifier("receive.create")
        } footer: {
            Text(rail == .lightning
                 ? "Creates a BOLT 11 invoice payable into your Wavelength wallet."
                 : "Creates a fresh boarding address tracked by the wallet’s Esplora-based chain backend.")
        }
    }

    private var paymentRequest: some View {
        Group {
            Section {
                VStack(spacing: 18) {
                    QRCodeView(value: request)
                        .frame(width: 230, height: 230)
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityLabel("Payment request QR code")

                    Text(rail == .lightning ? "Lightning invoice" : "Bitcoin address")
                        .font(.headline)
                    if amountSat > 0 {
                        Text(WalletFormatting.sats(amountSat))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                Text(request)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .privacySensitive()
                    .accessibilityIdentifier("receive.request")
                Button {
                    UIPasteboard.general.string = request
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("receive.copy")
                Button {
                    showingShare = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            Section {
                Button("Create Another Request") { request = "" }
            }
        }
    }

    private var canCreate: Bool {
        store.isReady && store.operatorAvailable &&
            (rail == .onchain || (amountSat > 0 && store.offchainAvailable))
    }

    private func createRequest() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                switch rail {
                case .lightning:
                    let result = try await store.receiveLightning(
                        amountSat: amountSat,
                        memo: memo.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    request = result.invoice
                case .onchain:
                    let result = try await store.newDepositAddress(amountHintSat: amountSat)
                    request = result.address
                }
            } catch {
                errorMessage = error.walletMessage
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
