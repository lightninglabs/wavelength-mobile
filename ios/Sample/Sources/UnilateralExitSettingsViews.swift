import SwiftUI
import WalletKit

struct ExitSettingsRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(WalletTheme.secondary)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
    }
}

struct UnilateralExitDestinationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var address: String
    @State private var anotherAddress: Bool
    @State private var input: String

    init(address: Binding<String>) {
        _address = address
        _anotherAddress = State(initialValue: !address.wrappedValue.isEmpty)
        _input = State(initialValue: address.wrappedValue)
    }

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        WalletPage {
            VStack(spacing: 0) {
                ExitOptionRow(title: "My on-chain wallet", selected: !anotherAddress) { anotherAddress = false }
                WalletDivider()
                ExitOptionRow(title: "Another Bitcoin address", selected: anotherAddress) { anotherAddress = true }
            }
            if anotherAddress {
                WalletField(title: "Bitcoin address") {
                    HStack {
                        TextField("Paste a Bitcoin address", text: $input)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("unilateral.address")
                        if #available(iOS 16.0, *) {
                            PasteButton(payloadType: String.self) { values in
                                if let value = values.first { input = value }
                            }
                            .labelStyle(.iconOnly)
                        } else {
                            Button("Paste") { input = UIPasteboard.general.string ?? "" }
                        }
                    }
                }
            }
        }
        .navigationTitle("Destination").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ExitFooter {
                Button("Apply") {
                    address = anotherAddress ? trimmed : ""
                    dismiss()
                }
                .buttonStyle(WalletButtonStyle())
                .disabled(anotherAddress && trimmed.isEmpty)
                .accessibilityIdentifier("unilateral.applyAddress")
            }
        }
    }
}

struct UnilateralExitFeeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var rate: Int64
    let automaticRate: Int64?
    @State private var custom: Bool
    @State private var input: String

    init(rate: Binding<Int64>, automaticRate: Int64?) {
        _rate = rate
        self.automaticRate = automaticRate
        _custom = State(initialValue: rate.wrappedValue > 0)
        _input = State(initialValue: rate.wrappedValue > 0 ? String(rate.wrappedValue) : "")
    }

    private var selectedRate: Int64? {
        if !custom { return 0 }
        guard let parsed = Int64(input), parsed > 0 else { return nil }
        return parsed
    }

    var body: some View {
        WalletPage {
            VStack(spacing: 0) {
                ExitOptionRow(title: "Automatic", detail: automaticRate.map { "\($0) sat/vB" },
                              selected: !custom) { custom = false }
                WalletDivider()
                ExitOptionRow(title: "Custom", selected: custom) { custom = true }
            }
            if custom {
                WalletField(title: "Fee rate") {
                    HStack {
                        TextField("Fee rate", text: $input)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("unilateral.feeRate")
                        Text("sat/vB").foregroundStyle(WalletTheme.secondary)
                    }
                }
                Text("We’ll recheck the exit with this rate.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
        }
        .navigationTitle("Fee rate").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ExitFooter {
                Button("Apply and recheck") {
                    guard let selectedRate else { return }
                    rate = selectedRate
                    dismiss()
                }
                .buttonStyle(WalletButtonStyle())
                .disabled(selectedRate == nil)
                .accessibilityIdentifier("unilateral.applyFee")
            }
        }
    }
}

private struct ExitOptionRow: View {
    let title: String
    var detail: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? WalletTheme.action : WalletTheme.secondary)
                    .accessibilityHidden(true)
                Text(title)
                Spacer()
                if let detail { Text(detail).foregroundStyle(WalletTheme.secondary) }
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
