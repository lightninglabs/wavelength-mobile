import SwiftUI

struct WalletShellView: View {
    var body: some View {
        NavigationView { WalletDashboardView() }
            .navigationViewStyle(.stack)
    }
}

private enum WalletSheet: String, Identifiable {
    case send, receive
    var id: String { rawValue }
}

private struct WalletDashboardView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: WalletSheet?
    @State private var showsRefresh = false

    var body: some View {
        WalletPage {
            VStack(alignment: .leading, spacing: 12) {
                Text("Balance").foregroundStyle(WalletTheme.secondary)
                if let balance = store.balance {
                    WalletAmount(amount: balance.totalSat)
                        .accessibilityIdentifier("wallet.balance")
                    if balance.pendingSat > 0 {
                        Text("\(WalletFormatting.sats(balance.pendingSat)) pending")
                            .font(.subheadline)
                            .foregroundStyle(WalletTheme.secondary)
                            .accessibilityIdentifier("wallet.balance.pending")
                    }
                } else {
                    WalletLoadingIndicator(label: "Loading balance")
                        .frame(height: 58)
                }
            }
            .padding(.top, 12)
            HStack(spacing: 12) {
                Button { sheet = .send } label: {
                    Label("Send", systemImage: "arrow.up.right")
                }
                .buttonStyle(WalletButtonStyle())
                .disabled(!store.isReady)
                .accessibilityIdentifier("wallet.send")
                Button { sheet = .receive } label: {
                    Label("Receive", systemImage: "arrow.down.left")
                }
                .buttonStyle(WalletButtonStyle(secondary: true))
                .disabled(!store.isReady)
                .accessibilityIdentifier("wallet.receive")
            }
            if let credit = store.balance?.creditAvailableSat, credit > 0 {
                VStack(spacing: 16) {
                    WalletDivider()
                    NavigationLink(destination: CreditSettingsView()) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Credit")
                                Text("Provider-held").font(.caption).foregroundStyle(WalletTheme.secondary)
                            }
                            Spacer()
                            Text(WalletFormatting.sats(credit)).monospacedDigit()
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("wallet.credit")
                    WalletDivider()
                }
            }
            if store.isSyncing {
                WalletStatus(text: "Connecting", pending: true)
                    .foregroundStyle(WalletTheme.secondary)
            }
            if store.recoverableAmountSat > 0 {
                Button { showsRefresh = true } label: {
                    HStack {
                        Text("Recovery available")
                        Spacer()
                        Text(WalletFormatting.sats(store.recoverableAmountSat))
                        Image(systemName: "chevron.right").font(.caption)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Activity").font(.title2.weight(.medium)).padding(.bottom, 8)
                if let refresh = store.refreshOperation {
                    Button { showsRefresh = true } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "arrow.triangle.2.circlepath").frame(width: 24).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Refresh")
                                    Spacer()
                                    if refresh.amountSat > 0 { Text(WalletFormatting.sats(refresh.amountSat)) }
                                }
                                WalletStatus(text: refresh.status, pending: refresh.status == "In progress")
                                    .foregroundStyle(WalletTheme.secondary)
                            }
                        }.padding(.vertical, 17).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    WalletDivider()
                }

                if store.visibleActivity.isEmpty && !store.activityLoaded {
                    WalletLoadingIndicator(label: "Loading activity")
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                } else if store.visibleActivity.isEmpty && store.refreshOperation == nil {
                    Text("No activity").foregroundStyle(WalletTheme.secondary).padding(.vertical, 16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(store.visibleActivity) { entry in
                            NavigationLink(destination: ActivityDetailView(entry: entry)) {
                                ActivityRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("activity.entry")
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                            WalletDivider()
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: store.visibleActivity.map(\.id))
                }
            }
        }
        .background {
            // Keep the destination mounted when clearing a completed or
            // released operation removes its conditional Activity row.
            NavigationLink(destination: RefreshWalletView(), isActive: $showsRefresh) { EmptyView() }
                .hidden()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                WavelengthWordmark()
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gearshape").foregroundStyle(WalletTheme.foreground)
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("wallet.settings")
            }
        }
        .refreshable { await store.refresh() }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .send: SendView().environmentObject(store)
            case .receive: ReceiveView().environmentObject(store)
            }
        }
    }
}
