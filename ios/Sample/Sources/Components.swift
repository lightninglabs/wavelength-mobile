import SwiftUI
import WalletKit

struct WavelengthMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.orange, Color(red: 1, green: 0.42, blue: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "wave.3.right")
                .font(.system(size: size * 0.43, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .orange.opacity(0.25), radius: 14, y: 8)
        .accessibilityHidden(true)
    }
}

struct NetworkBadge: View {
    let network: WalletNetwork

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(network.color).frame(width: 7, height: 7)
            Text(network.title)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(network.color.opacity(0.12), in: Capsule())
        .foregroundStyle(network.color)
        .accessibilityLabel("Bitcoin network: \(network.title)")
    }
}

/// Opens the network chooser from screens that cannot reach the Settings tab,
/// such as first-run setup, unlock, and daemon-start failure states.
struct NetworkSelectionButton: View {
    @EnvironmentObject private var store: WalletStore
    @State private var showingNetworks = false

    var body: some View {
        Button {
            showingNetworks = true
        } label: {
            HStack(spacing: 7) {
                NetworkBadge(network: store.network)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change Bitcoin network. Current network: \(store.network.title)")
        .sheet(isPresented: $showingNetworks) {
            NetworkSelectionView()
                .environmentObject(store)
        }
    }
}

private struct NetworkSelectionView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.presentationMode) private var presentationMode
    @State private var proposedMainnet = false
    @State private var isSwitching = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(WalletNetwork.selectableNetworks, id: \.rawValue) { network in
                        Button {
                            select(network)
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(network.color)
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(network.title)
                                        .foregroundStyle(.primary)
                                    Text(network.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.network == network {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(network.color)
                                }
                            }
                        }
                        .disabled(isSwitching || store.network == network)
                    }
                } header: {
                    Text("Bitcoin network")
                } footer: {
                    Text("Each network has an isolated wallet database, balance, activity history, and device encryption key. Switching never moves funds between networks.")
                }

                if isSwitching {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Starting \(store.network.title)…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Choose Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(isSwitching)
                }
            }
            .confirmationDialog(
                "Use real bitcoin on Mainnet?",
                isPresented: $proposedMainnet,
                titleVisibility: .visible
            ) {
                Button("Switch to Mainnet", role: .destructive) {
                    switchTo(.mainnet)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Mainnet uses a separate wallet and real funds. Off-chain operations remain unavailable until you configure trusted services.")
            }
        }
        .navigationViewStyle(.stack)
    }

    private func select(_ network: WalletNetwork) {
        guard network != store.network else { return }
        if network == .mainnet {
            proposedMainnet = true
        } else {
            switchTo(network)
        }
    }

    private func switchTo(_ network: WalletNetwork) {
        isSwitching = true
        Task {
            await store.switchNetwork(to: network)
            presentationMode.wrappedValue.dismiss()
        }
    }
}

struct ActivityRow: View {
    let entry: Entry

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ActivityRailIcon(entry: entry)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.activityTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    Spacer(minLength: 4)

                    Text(entry.activityAmountText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(entry.activityAmountColor)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    Spacer(minLength: 4)

                    StatusLabel(status: entry.status)
                        .fixedSize()
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let context: String
        if let date = WalletFormatting.date(entry.createdAt) {
            context = date
        } else if !entry.note.isEmpty {
            context = entry.note
        } else if !entry.counterparty.isEmpty {
            context = WalletFormatting.shortened(entry.counterparty)
        } else {
            context = WalletFormatting.shortened(entry.id)
        }
        return "\(entry.activityDirectionLabel) · \(context)"
    }
}

/// The large glyph identifies the payment rail; the small badge identifies
/// direction. That keeps Lightning/on-chain and incoming/outgoing as two
/// independent, consistently represented pieces of information.
struct ActivityRailIcon: View {
    let entry: Entry
    var size: CGFloat = 42

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(entry.activityColor.opacity(0.12))
                .frame(width: size, height: size)

            Image(systemName: entry.isLightningActivity ? "bolt.fill" : "bitcoinsign")
                .font(.system(size: size * 0.41, weight: .semibold))
                .foregroundStyle(entry.activityColor)
                .frame(width: size, height: size)

            ZStack {
                Circle()
                    .fill(entry.activityColor)
                Image(systemName: entry.isCredit ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: size * 0.20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size * 0.42, height: size * 0.42)
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Entry {
    var activityColor: Color {
        switch status {
        case "failed": return .red
        case "pending": return .orange
        default: return isCredit ? .green : .blue
        }
    }

    var isCredit: Bool { kind == "receive" || kind == "deposit" }

    var isLightningActivity: Bool {
        if request?.type.lowercased() == "lightning" { return true }
        if request?.type.lowercased() == "onchain" { return false }
        if kind == "receive" { return true }
        if kind == "deposit" || kind == "exit" { return false }
        return !(progress?.paymentHash ?? "").isEmpty
    }

    var activityDirectionLabel: String {
        if isAwaitingIncomingPayment { return "Incoming request" }
        return isCredit ? "Incoming" : "Outgoing"
    }

    /// A newly issued invoice/address is an invitation to pay, not evidence
    /// that money was received. Keep requested amounts visually distinct until
    /// Wavelength reports payment detection or a later lifecycle phase.
    var isAwaitingIncomingPayment: Bool {
        guard isCredit, status == "pending" else { return false }
        let phase = progress?.phase ?? ""
        let label = progress?.phaseLabel ?? ""
        let requestOnlyPhases = [
            "request_created", "waiting_for_payment", "address_issued",
        ]
        let lifecycle = label.isEmpty ? phase : label
        return lifecycle.isEmpty || requestOnlyPhases.contains(lifecycle)
    }

    var activityTitle: String {
        switch kind {
        case "send":
            if status == "failed" {
                return isLightningActivity ? "Lightning send failed" : "On-chain send failed"
            }
            if isLightningActivity {
                return status == "complete" ? "Lightning sent" : "Lightning send"
            }
            return status == "complete" ? "On-chain sent" : "On-chain send"
        case "receive":
            if status == "complete" { return "Lightning received" }
            if status == "failed" { return "Lightning receive failed" }
            return isAwaitingIncomingPayment ? "Lightning invoice" : "Lightning receive"
        case "deposit":
            if status == "failed" { return "On-chain deposit failed" }
            return isAwaitingIncomingPayment ? "On-chain address" : "On-chain deposit"
        case "exit":
            return "On-chain exit"
        default:
            return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var activityAmountText: String {
        if isAwaitingIncomingPayment {
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
        if isAwaitingIncomingPayment { return .secondary }
        if isCredit, status == "pending" { return .primary }
        return isCredit ? .green : .primary
    }
}

struct StatusLabel: View {
    let status: String

    var body: some View {
        Text(status.capitalized)
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch status {
        case "complete": return .green
        case "failed": return .red
        default: return .orange
        }
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
