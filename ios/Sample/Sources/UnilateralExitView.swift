import SwiftUI
import WalletKit

struct UnilateralExitView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var funds: [WalletVTXO]?
    @State private var selected: String?
    @State private var reviewFund: WalletVTXO?
    @State private var showsReview = false
    @State private var error: String?

    private var available: [WalletVTXO] {
        let active = Set(store.recoveryJobs.map(\.outpoint))
        return (funds ?? []).filter { $0.status != "unilateral_exit" && !active.contains($0.outpoint) }
    }

    var body: some View {
        let available = available
        let selection = available.first { $0.outpoint == selected }
        WalletPage {
            if !store.recoveryJobs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Exit queue").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(store.recoveryJobs) { job in
                        NavigationLink(destination: RecoveryStatusView(outpoint: job.outpoint, amount: job.vtxoAmountSat)
                            .environmentObject(store)) {
                            VStack(alignment: .leading, spacing: 4) {
                                WalletNavigationRow(title: WalletFormatting.sats(job.vtxoAmountSat))
                                Text(UnilateralExitStage(status: job.status).title)
                                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(WalletTheme.secondary)
                Button("Try again") { Task { await loadFunds() } }
                    .buttonStyle(WalletButtonStyle(secondary: true))
            } else if funds == nil {
                WalletLoadingIndicator(label: "Checking funds")
            } else if available.isEmpty {
                Text("No available funds").foregroundStyle(WalletTheme.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Total available").foregroundStyle(WalletTheme.secondary)
                    WalletAmount(amount: available.reduce(0) { $0 + $1.amountSat })
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Choose funds").font(.headline).accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 10)
                    ForEach(available, id: \.outpoint) { fund in
                        Button { selected = fund.outpoint } label: {
                            HStack {
                                Text(WalletFormatting.sats(fund.amountSat))
                                Spacer()
                                Image(systemName: selected == fund.outpoint ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected == fund.outpoint ? WalletTheme.action : WalletTheme.secondary)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected == fund.outpoint ? .isSelected : [])
                        WalletDivider()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if error == nil, !available.isEmpty {
                ExitFooter {
                    if let selection {
                        ExitValueLine(label: "Selected", value: WalletFormatting.sats(selection.amountSat))
                    }
                    Button("Review exit") {
                        reviewFund = selection
                        showsReview = true
                    }
                    .buttonStyle(WalletButtonStyle())
                    .disabled(selection == nil)
                    .accessibilityIdentifier("unilateral.review")
                }
            }
        }
        .background {
            // Keep the destination mounted when the selection becomes an active exit.
            NavigationLink(isActive: $showsReview) {
                if let reviewFund { UnilateralExitReviewView(fund: reviewFund).environmentObject(store) }
            } label: { EmptyView() }
            .hidden()
        }
        .navigationTitle("Unilateral exit").navigationBarTitleDisplayMode(.inline)
        .task { await loadFunds() }
        .refreshable { await loadFunds() }
    }

    private func loadFunds() async {
        error = nil
        do { funds = try await store.recoveryFunds() }
        catch {
            if !Task.isCancelled { self.error = "Couldn’t load funds for exit." }
        }
    }
}

private struct UnilateralExitReviewView: View {
    let fund: WalletVTXO
    @EnvironmentObject private var store: WalletStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var plan: ExitPlan?
    @State private var funding: UnilateralExitFunding?
    @State private var checkingPlan = false
    @State private var planFailed = false
    @State private var submitted = false
    @State private var startError: String?
    @State private var showsQR = false

    private var entry: ExitPlanEntry? { plan?.plans?.first { $0.outpoint == fund.outpoint } }
    private var canStart: Bool { !checkingPlan && !planFailed && entry?.exitJobFound == false && entry?.canStart == true }
    private var fundingOffer: UnilateralExitFunding? { entry.flatMap(UnilateralExitFunding.init) }

    private var awaitingFunding: Bool {
        funding != nil && fundingOffer != nil
    }

    var body: some View {
        Group {
            if submitted {
                RecoveryStatusView(outpoint: fund.outpoint, amount: fund.amountSat, startError: startError)
            } else {
                WalletPage {
                    if let funding, awaitingFunding {
                        fundingInstructions(funding)
                    } else {
                        review
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
                .navigationTitle(awaitingFunding ? "Fund network fees" : "Review exit")
                .navigationBarTitleDisplayMode(.inline)
                .refreshable { await loadPlan() }
            }
        }
        .task { await loadPlan() }
        .task(id: awaitingFunding && scenePhase == .active && !store.isSessionLocked) {
            guard awaitingFunding, scenePhase == .active, !store.isSessionLocked else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                await loadPlan()
            }
        }
    }

    @ViewBuilder private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selected to exit").foregroundStyle(WalletTheme.secondary)
            WalletAmount(amount: fund.amountSat)
        }
        .padding(.bottom, 12)
        if canStart {
            WalletStatus(text: "Ready to exit", complete: true)
            if let entry, !entry.roundCommitment.isEmpty {
                Text("These funds are in an active round. Starting the exit may interrupt it.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
        }
        if let rate = plan?.feeRateSatPerVByte, rate > 0 {
            ExitValueLine(label: "Estimated fee rate", value: "Automatic · \(rate) sat/vB")
        }
        if let fundingOffer {
            ExitValueLine(label: "Fee funding needed", value: fundingOffer.summary)
        }
        ValueRow(label: "To", value: "My on-chain wallet")
        if let entry, !entry.canStart, !entry.exitJobFound, fundingOffer == nil {
            Text(blockedMessage(entry)).font(.footnote).foregroundStyle(WalletTheme.secondary)
        }
        if checkingPlan {
            WalletLoadingIndicator(label: "Checking exit plan")
        } else if planFailed {
            Text("Couldn’t check the exit plan.").foregroundStyle(WalletTheme.secondary)
            Button("Try again") { Task { await loadPlan() } }
                .buttonStyle(WalletButtonStyle(secondary: true))
        }
    }

    private func fundingInstructions(_ funding: UnilateralExitFunding) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add funds for fees").font(.title2.weight(.medium))
            Text(funding.instructions)
            VStack(alignment: .leading, spacing: 16) {
                ValueRow(label: "Fee funding address", value: funding.address, copyable: true)
                Button(showsQR ? "Hide QR" : "Show QR") { showsQR.toggle() }
                if showsQR {
                    QRCodeView(value: funding.address)
                        .frame(width: 210, height: 210)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
            .background(WalletTheme.surface, in: RoundedRectangle(cornerRadius: 15))
            Text("Wait for your payments to confirm before sending more.")
                .font(.footnote).foregroundStyle(WalletTheme.secondary)
        }
    }

    @ViewBuilder private var footer: some View {
        if awaitingFunding, let entry {
            ExitFooter {
                WalletStatus(text: planFailed ? "Couldn’t check funding" : "Waiting for confirmation",
                             pending: !planFailed)
                let usable = min(entry.usableFeeUTXOCount, entry.requiredFeeUTXOCount)
                Text("\(usable) of \(entry.requiredFeeUTXOCount) ready for fees")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
        } else if let entry, entry.exitJobFound {
            ExitFooter {
                NavigationLink(destination: RecoveryStatusView(outpoint: fund.outpoint, amount: fund.amountSat)
                    .environmentObject(store)) {
                    Text("View exit progress")
                }.buttonStyle(WalletButtonStyle())
            }
        } else if canStart {
            ExitFooter {
                Text("Once started, this exit can’t be undone.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
                Button("Start unilateral exit", action: submit)
                    .buttonStyle(WalletButtonStyle())
                    .accessibilityIdentifier("recovery.confirm")
            }
        } else if let fundingOffer, !checkingPlan, !planFailed {
            ExitFooter {
                Button("Continue to funding") { funding = fundingOffer }
                    .buttonStyle(WalletButtonStyle())
            }
        }
    }

    private func loadPlan() async {
        guard !checkingPlan, !submitted else { return }
        checkingPlan = true
        defer { checkingPlan = false }
        do {
            let result = try await store.exitPlan(outpoint: fund.outpoint)
            try Task.checkCancellation()
            guard !submitted else { return }
            plan = result
            planFailed = result.plans?.contains { $0.outpoint == fund.outpoint } != true
            if !planFailed && fundingOffer == nil { funding = nil }
        } catch {
            if !Task.isCancelled { planFailed = true }
        }
    }

    private func blockedMessage(_ entry: ExitPlanEntry) -> String {
        if !entry.roundCommitment.isEmpty { return "These funds are already in an active round." }
        switch entry.infeasibilityReason {
        case "sweep_below_dust": return "These funds are too small to exit at the current fee."
        case "uneconomical": return "The estimated fees are too high for this amount."
        default: return "The wallet can’t start this exit right now."
        }
    }

    private func submit() {
        guard canStart, !submitted else { return }
        // An ambiguous native response still belongs to this exit.
        submitted = true
        Task {
            do { _ = try await store.exitFunds(outpoint: fund.outpoint, destination: "", unilateral: true) }
            catch { startError = error.walletMessage }
        }
    }
}

struct UnilateralExitFunding {
    let address: String
    let paymentCount: Int64
    let satsPerPayment: Int64

    init?(_ entry: ExitPlanEntry) {
        let missingInputs = Int64(entry.requiredFeeUTXOCount) - Int64(entry.usableFeeUTXOCount)
        let needsFunding = entry.fundingShortfallSat > 0 ||
            (entry.infeasibilityReason == "wallet_too_few_inputs" && missingInputs > 0)
        guard !entry.canStart, !entry.exitJobFound, entry.error.isEmpty,
              entry.roundCommitment.isEmpty, !entry.fundingAddress.isEmpty, needsFunding else { return nil }
        address = entry.fundingAddress
        paymentCount = max(1, missingInputs)
        let shortfall = max(0, entry.fundingShortfallSat)
        let minimum = shortfall / paymentCount + (shortfall % paymentCount == 0 ? 0 : 1)
        satsPerPayment = max(entry.recommendedUTXOAmountSat, minimum)
        guard satsPerPayment > 0 else { return nil }
    }

    var summary: String {
        let amount = WalletFormatting.sats(satsPerPayment)
        return paymentCount == 1 ? amount : "\(paymentCount) × \(amount)"
    }

    var instructions: String {
        let amount = WalletFormatting.sats(satsPerPayment)
        return paymentCount == 1 ? "Send \(amount) to this address."
            : "Send \(paymentCount) separate payments of \(amount) each."
    }
}

enum UnilateralExitStage: Equatable {
    case checking, publishing, waiting, sweeping, complete, failed

    init(status: String?) {
        switch status {
        case "materializing": self = .publishing
        case "csv_pending": self = .waiting
        case "sweeping": self = .sweeping
        case "completed": self = .complete
        case "failed": self = .failed
        default: self = .checking
        }
    }

    var title: String {
        switch self {
        case .checking: return "Checking exit status"
        case .publishing: return "Publishing exit transactions"
        case .waiting: return "Waiting for block delay"
        case .sweeping: return "Sweep confirming"
        case .complete: return "Exit complete"
        case .failed: return "Action needed"
        }
    }

    var isTerminal: Bool { self == .complete || self == .failed }
}

private struct ExitFooter<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 12, content: content)
            .foregroundStyle(WalletTheme.foreground)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .background(WalletTheme.background)
    }
}

private struct ExitValueLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(WalletTheme.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}
