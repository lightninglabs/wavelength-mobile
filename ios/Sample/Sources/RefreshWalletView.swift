import SwiftUI
import WalletKit

struct RefreshWalletView: View {
    var showsRefreshReceipt = false
    @EnvironmentObject private var store: WalletStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsOperation = false
    @State private var funds: [WalletVTXO]?
    @State private var loadedScreen: Screen?
    @State private var preview: RefreshPreview?
    @State private var isStarting = false
    @State private var loadError: String?
    @State private var startError: String?

    private var screen: Screen {
        guard let operation = store.refreshOperation else { return .review }
        if operation.isResolved {
            guard followsOperation || showsRefreshReceipt else { return .review }
            return operation.status == "Complete" ? .complete : .retry(operation.remainingOutpoints ?? [])
        }
        return .tracking(operation.outpoints)
    }

    var body: some View {
        let screen = screen
        let groups = RefreshExpiryGroup.group(funds ?? [], at: store.info?.blockHeight)
        ScrollViewReader { scroll in
            page(screen, groups: groups)
                .onChange(of: isStarting) { starting in
                    if starting {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            scroll.scrollTo("refresh.summary", anchor: .top)
                        }
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let preview, preview.screen == screen, !isStarting {
                footer(preview)
            }
        }
        .navigationTitle("Refresh").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if store.refreshOperation?.isResolved == false {
                followsOperation = true
            }
        }
        .task(id: screen) { await load(screen) }
        .refreshable { await load(screen) }
    }

    private func page(_ screen: Screen, groups: [RefreshExpiryGroup]) -> some View {
        WalletPage {
            summary(screen, groups: groups).id("refresh.summary")
            if !groups.isEmpty { expiryList(groups, showsWalletInventory: screen == .complete) }
            if let message = startError ?? loadError ?? (screen.isTracking ? store.refreshCheckError : nil) {
                Text(message).font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            if loadError != nil && !isStarting {
                Button("Try again") { Task { await load(screen) } }
                    .buttonStyle(WalletButtonStyle(secondary: true))
            }
        }
    }

    private func summary(_ screen: Screen, groups: [RefreshExpiryGroup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if screen == .complete {
                if let operation = store.refreshOperation {
                    let amount = operation.confirmedAmountSat ?? operation.amountSat
                    if amount > 0 { WalletAmount(amount: amount) }
                }
            } else if !groups.isEmpty {
                WalletAmount(amount: groups.reduce(0) { $0 + $1.amountSat })
            } else if screen.isTracking, let amount = store.refreshOperation?.amountSat, amount > 0 {
                WalletAmount(amount: amount)
            }
            status(screen).foregroundStyle(WalletTheme.secondary)
        }
    }

    @ViewBuilder private func status(_ screen: Screen) -> some View {
        if isStarting {
            WalletStatus(text: "Starting refresh", pending: true)
        } else {
            switch screen {
            case .review:
                if preview?.screen == screen {
                    Text("Refresh to keep these funds spendable in Wavelength.").font(.subheadline)
                } else if loadedScreen == .review, funds?.isEmpty == true {
                    Text("Nothing to refresh right now")
                } else if loadError == nil {
                    WalletLoadingIndicator(label: "Checking funds to refresh")
                }
            case .tracking:
                if store.refreshCheckError != nil || store.refreshOperation?.status != "In progress" {
                    WalletStatus(text: "Checking refresh status", pending: store.isCheckingRefresh)
                } else {
                    WalletStatus(text: "Refresh in progress", pending: true)
                    Text("You can check back in Activity.").font(.footnote)
                }
            case .retry:
                if let amount = store.refreshOperation?.confirmedAmountSat, amount > 0 {
                    Text("\(WalletFormatting.sats(amount)) refreshed")
                }
                if let preview, preview.screen == screen {
                    Text("\(WalletFormatting.sats(preview.amountSat)) ready to refresh")
                } else if loadedScreen == screen {
                    Text("Nothing to refresh right now")
                } else if loadError == nil {
                    WalletLoadingIndicator(label: "Checking remaining funds")
                }
            case .complete:
                if loadedScreen == .complete {
                    WalletStatus(text: "Refreshed", complete: true)
                } else if loadError == nil {
                    WalletStatus(text: "Updating expiry", pending: true)
                }
            }
        }
    }

    private func expiryList(_ groups: [RefreshExpiryGroup], showsWalletInventory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(showsWalletInventory ? "Wallet fund expiries" : "When your funds expire")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(WalletTheme.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    if group.id != groups.first?.id { WalletDivider() }
                    HStack(spacing: 12) {
                        Image(systemName: "clock")
                            .foregroundStyle(WalletTheme.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(WalletFormatting.sats(group.amountSat)).font(.body.weight(.medium))
                            Text(group.expiry.label).font(.subheadline).foregroundStyle(WalletTheme.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .accessibilityElement(children: .combine)
                    .privacySensitive()
                }
            }
            .background(WalletTheme.surface, in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private func footer(_ preview: RefreshPreview) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("Estimated fee").foregroundStyle(WalletTheme.secondary)
                Spacer()
                Text(preview.feeSat.map { WalletFormatting.sats($0) } ?? "Unavailable")
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)
            Button("Start refresh") {
                isStarting = true
                startError = nil
                Task {
                    defer { isStarting = false }
                    do {
                        try await store.startRefresh(outpoints: preview.outpoints, amountSat: preview.amountSat)
                        followsOperation = true
                    } catch {
                        if !screen.isTracking { startError = "Couldn’t start refresh. Try again." }
                    }
                }
            }
            .buttonStyle(WalletButtonStyle())
            .accessibilityIdentifier("refresh.start")
        }
        .foregroundStyle(WalletTheme.foreground)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(WalletTheme.background)
    }

    private func load(_ screen: Screen) async {
        guard !Task.isCancelled, screen == self.screen else { return }
        if screen != .review { followsOperation = true }
        preview = nil
        loadError = nil
        startError = nil
        let network = store.network
        do {
            if screen.isTracking {
                await store.checkRefreshStatus()
                guard screen == self.screen else { return }
                // Keep the list the user reviewed while the round is pending.
                if funds != nil { return }
            }

            let inventory = try await store.recoveryFunds()
            let available = inventory.filter { $0.status == "live" || $0.status == "expired" }
            let result: RefreshResult?
            switch screen {
            case .review:
                result = try await store.previewRefresh()
            case .retry(let remaining):
                // The released funds may have been spent since the receipt.
                // Price only those still available, including expired funds.
                let eligible = Set(available.map(\.outpoint))
                let retry = remaining.filter { eligible.contains($0) }
                result = retry.isEmpty ? nil : try await store.previewRefresh(outpoints: retry)
            case .tracking, .complete:
                result = nil
            }
            try Task.checkCancellation()
            guard screen == self.screen, network == store.network else { return }

            let outpoints = result?.queuedOutpoints ?? []
            let selected = Set(outpoints)
            let selectedFunds = available.filter { selected.contains($0.outpoint) }
            if !selected.isEmpty {
                // The amount beside the quote must cover the exact same inputs.
                guard selectedFunds.count == selected.count else {
                    loadError = "Funds changed. Check again for an updated estimate."
                    return
                }
                preview = RefreshPreview(screen: screen, outpoints: outpoints,
                    amountSat: selectedFunds.reduce(0) { $0 + $1.amountSat }, feeSat: result?.feeEstimate?.totalFeeSat)
            }
            switch screen {
            case .review, .retry: funds = selectedFunds
            case .tracking(let outpoints):
                let pending = Set(outpoints)
                funds = inventory.filter { pending.contains($0.outpoint) }
            case .complete:
                funds = available
            }
            loadedScreen = screen
        } catch {
            guard !Task.isCancelled, screen == self.screen, network == store.network else { return }
            loadError = screen == .complete ? "Couldn’t update expiry." : "Couldn’t load the refresh details."
        }
    }

    private enum Screen: Equatable {
        case review, tracking([String]), retry([String]), complete

        var isTracking: Bool {
            if case .tracking = self { return true }
            return false
        }
    }

    private struct RefreshPreview {
        let screen: Screen
        let outpoints: [String]
        let amountSat: Int64
        let feeSat: Int64?
    }
}

struct RefreshExpiryGroup: Identifiable, Equatable {
    enum Expiry: Hashable {
        case expired, lessThanAnHour, hours(Int64), days(Int64), unknown

        init(fund: WalletVTXO, height: Int64?) {
            if fund.status == "expired" {
                self = .expired
                return
            }
            guard let height, height > 0, let expiry = fund.batchExpiry, expiry > 0 else {
                self = .unknown
                return
            }
            // Estimates use Bitcoin's ten-minute target block interval.
            let blocks = Int64(expiry) - height
            let hours = (blocks + 3) / 6
            if blocks <= 0 { self = .expired }
            else if blocks < 6 { self = .lessThanAnHour }
            else if hours < 24 { self = .hours(hours) }
            else { self = .days((blocks + 72) / 144) }
        }

        var label: String {
            switch self {
            case .expired: return "Expired"
            case .lessThanAnHour: return "In less than an hour"
            case .hours(1): return "In about 1 hour"
            case .hours(let hours): return "In about \(hours) hours"
            case .days(1): return "In about 1 day"
            case .days(let days): return "In about \(days) days"
            case .unknown: return "Expiry unavailable"
            }
        }

        var sortOrder: Int64 {
            switch self {
            case .expired: return -1
            case .lessThanAnHour: return 0
            case .hours(let hours): return hours
            case .days(let days): return days * 24
            case .unknown: return .max
            }
        }
    }

    let expiry: Expiry
    let amountSat: Int64
    var id: Expiry { expiry }

    static func group(_ funds: [WalletVTXO], at height: Int64?) -> [Self] {
        Dictionary(grouping: funds, by: { Expiry(fund: $0, height: height) })
            .map { expiry, funds in Self(expiry: expiry, amountSat: funds.reduce(0) { $0 + $1.amountSat }) }
            .sorted { $0.expiry.sortOrder < $1.expiry.sortOrder }
    }
}
