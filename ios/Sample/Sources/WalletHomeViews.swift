import SwiftUI

struct WalletShellView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationView {
                WalletDashboardView(showAllActivity: { selectedTab = 1 })
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("Wallet", systemImage: "bitcoinsign.circle.fill") }
            .tag(0)

            NavigationView {
                ActivityListView()
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("Activity", systemImage: "clock.fill") }
            .tag(1)

            NavigationView {
                SettingsView()
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(2)
        }
    }
}

private struct WalletDashboardView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var showingSend = false
    @State private var showingReceive = false
    let showAllActivity: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if store.isSyncing {
                    syncBanner
                }

                balanceCard
                actionButtons
                recentActivity
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Wavelength")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NetworkBadge(network: store.network)
            }
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: $showingSend) {
            SendView().environmentObject(store)
        }
        .sheet(isPresented: $showingReceive) {
            ReceiveView().environmentObject(store)
        }
    }

    private var syncBanner: some View {
        HStack(spacing: 12) {
            ProgressView().tint(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Syncing with Bitcoin").font(.subheadline.weight(.semibold))
                Text("Height \(store.info?.blockHeight ?? 0) · spending unlocks when ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Available balance")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.white.opacity(0.86))
                    .accessibilityLabel("Self-custodial wallet")
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(WalletFormatting.satoshis.string(
                    from: NSNumber(value: store.confirmedBalanceSat)
                ) ?? "0")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Text("sats")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.76))
            }

            HStack(spacing: 22) {
                pendingValue(title: "Incoming", value: store.pendingInSat, icon: "arrow.down.left")
                pendingValue(title: "Outgoing", value: store.pendingOutSat, icon: "arrow.up.right")
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(
            LinearGradient(
                colors: [Color(red: 0.15, green: 0.13, blue: 0.20), Color(red: 0.33, green: 0.17, blue: 0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24)
        )
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wallet.balance")
    }

    private func pendingValue(title: String, value: Int64, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.66))
            Text(WalletFormatting.sats(value))
                .font(.caption.weight(.semibold))
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            walletAction(title: "Send", systemImage: "arrow.up", enabled: store.isReady) {
                showingSend = true
            }
            walletAction(title: "Receive", systemImage: "arrow.down", enabled: store.isReady) {
                showingReceive = true
            }
        }
        .padding(.horizontal, 24)
    }

    private func walletAction(
        title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(Color.orange, in: Circle())
                    .foregroundStyle(.white)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier("wallet.\(title.lowercased())")
        .accessibilityHint(enabled ? "" : "Available after wallet sync completes")
    }

    private var recentActivity: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent activity").font(.headline)
                Spacer()
                if !store.activity.isEmpty {
                    Button("See All", action: showAllActivity)
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(.bottom, 10)

            if store.activity.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No activity yet").font(.subheadline.weight(.medium))
                    Text("Send or receive bitcoin and it will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.activity.prefix(4).enumerated()), id: \.element.id) { index, entry in
                        NavigationLink(destination: ActivityDetailView(entry: entry)) {
                            ActivityRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("activity.entry")
                        if index < min(store.activity.count, 4) - 1 { Divider().padding(.leading, 55) }
                    }
                }
                .padding(.horizontal, 14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}
