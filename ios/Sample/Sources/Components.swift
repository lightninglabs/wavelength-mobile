import SwiftUI
import WalletKit

/// A single smooth wave, shared by the wordmark and launch artwork.
struct WavelengthMark: View {
    let size: CGFloat
    var body: some View {
        WavelengthWave()
            .stroke(WalletTheme.foreground,
                    style: StrokeStyle(lineWidth: max(2, size * 0.055), lineCap: .round))
            .frame(width: size, height: size * 0.42)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct WavelengthWave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.04, y: rect.midY))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.midY),
                      control1: CGPoint(x: rect.width * 0.22, y: rect.minY),
                      control2: CGPoint(x: rect.width * 0.28, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.width * 0.96, y: rect.midY),
                      control1: CGPoint(x: rect.width * 0.72, y: rect.maxY),
                      control2: CGPoint(x: rect.width * 0.78, y: rect.maxY))
        return path
    }
}

struct WavelengthWordmark: View {
    var body: some View {
        HStack(spacing: 9) {
            WavelengthMark(size: 28)
            Text("wavelength").font(.title3.weight(.medium))
        }
        .foregroundStyle(WalletTheme.foreground)
        .accessibilityElement(children: .combine)
    }
}

/// The same quiet network row is available before and after wallet unlock.
struct NetworkSelectionButton: View {
    @EnvironmentObject private var store: WalletStore
    @State private var route: NetworkPickerRoute?
    var body: some View {
        Button { route = NetworkPickerRoute() } label: {
            HStack {
                Text("Network")
                Spacer()
                Text(store.network.title).foregroundStyle(WalletTheme.secondary)
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(WalletTheme.secondary)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!store.canChangeNetwork)
        .accessibilityIdentifier("wallet.network")
        .sheet(item: $route) { _ in NetworkSelectionView().environmentObject(store) }
    }
    private struct NetworkPickerRoute: Identifiable { let id = "network" }
}

private struct NetworkSelectionView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.presentationMode) private var presentationMode
    @State private var proposedMainnet = false
    @State private var switching = false
    var body: some View {
        NavigationView {
            WalletPage {
                VStack(spacing: 0) {
                    ForEach(WalletNetwork.selectableNetworks, id: \.rawValue) { network in
                        Button { select(network) } label: {
                            HStack {
                                Text(network.title).font(.body.weight(.medium))
                                Spacer()
                                if store.network == network {
                                    Image(systemName: "checkmark").foregroundStyle(WalletTheme.action)
                                }
                            }
                            .frame(minHeight: 62)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(switching)
                        .accessibilityIdentifier("network.\(network.rawValue)")
                        .accessibilityAddTraits(store.network == network ? .isSelected : [])
                        WalletDivider()
                    }
                }
                if switching { WalletStatus(text: "Connecting", pending: true) }
            }
            .navigationTitle("Network").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }.disabled(switching)
                }
            }
            .confirmationDialog("Use Mainnet?", isPresented: $proposedMainnet, titleVisibility: .visible) {
                Button("Use Mainnet", role: .destructive) { switchTo(.mainnet) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Mainnet uses real bitcoin.") }
            .interactiveDismissDisabled(switching)
        }.navigationViewStyle(.stack)
    }
    private func select(_ network: WalletNetwork) {
        guard network != store.network else { presentationMode.wrappedValue.dismiss(); return }
        if network == .mainnet { proposedMainnet = true } else { switchTo(network) }
    }
    private func switchTo(_ network: WalletNetwork) {
        switching = true
        Task {
            await store.switchNetwork(to: network)
            presentationMode.wrappedValue.dismiss()
        }
    }
}

struct WalletNavigationRow: View {
    let title: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 14) {
            if let icon { Image(systemName: icon).frame(width: 24) }
            Text(title)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(WalletTheme.secondary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

struct ActivityRow: View {
    let entry: Entry
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ActivityRailIcon(entry: entry, size: 24)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.activityTitle).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(entry.activityAmountText)
                        .monospacedDigit()
                        .foregroundStyle(entry.activityAmountColor)
                        .multilineTextAlignment(.trailing)
                }
                WalletStatus(text: entry.displayStatus,
                             pending: entry.status == "pending" && !entry.isAwaitingIncomingPayment)
                    .font(.caption)
                    .foregroundStyle(WalletTheme.secondary)
            }
        }
        .padding(.vertical, 17)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ActivityRailIcon: View {
    let entry: Entry
    var size: CGFloat = 24
    var body: some View {
        Image(systemName: entry.kind == "refresh" ? "arrow.triangle.2.circlepath" :
                entry.kind == "exit" ? "arrow.up.right.square" :
                entry.isCredit ? "arrow.down.left" : "arrow.up.right")
            .font(.system(size: size * 0.8, weight: .regular))
            .frame(width: size, height: size)
            .foregroundStyle(WalletTheme.foreground)
            .accessibilityHidden(true)
    }
}

extension Entry {
    var activityAmountText: String {
        if isAwaitingIncomingPayment || isExpiredInvoice {
            guard amountSat > 0 else { return "Waiting for payment" }
            let suffix = kind == "receive" ? "requested" : "expected"
            return "\(WalletFormatting.sats(amountSat)) \(suffix)"
        }
        if isCredit, status == "pending" {
            return WalletFormatting.sats(amountSat)
        }
        let signedAmount = isCredit ? abs(amountSat) : -abs(amountSat)
        return WalletFormatting.sats(signedAmount, signed: true)
    }

    var activityAmountColor: Color {
        if isAwaitingIncomingPayment || isExpiredInvoice { return .secondary }
        if isCredit, status == "pending" { return .primary }
        return WalletTheme.foreground
    }
}

struct ExplorerValueRow: View {
    let label: String
    let value: String
    let destination: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                CopyButton(value: value)
            }
            Link(destination: destination) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value)
                        .font(.system(.callout, design: .monospaced))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right.square")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .font(.caption.weight(.medium))
        .accessibilityLabel(copied ? "Copied" : "Copy to clipboard")
    }
}

struct ValueRow: View {
    let label: String
    let value: String
    var copyable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                if copyable { CopyButton(value: value) }
            }
            Text(value)
                .font(.system(.callout, design: copyable ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
