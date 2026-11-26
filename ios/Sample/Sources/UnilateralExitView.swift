import SwiftUI
import WalletKit

struct UnilateralExitView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var funds: [WalletVTXO]?
    @State private var selected: Set<String> = []
    @State private var error: String?

    private var available: [WalletVTXO] {
        let active = Set(store.recoveryJobs.map(\.outpoint)).union(store.pendingExitOutpoints)
        return (funds ?? []).filter { $0.status != "unilateral_exit" && !active.contains($0.outpoint) }
    }

    var body: some View {
        let available = available
        let selection = available.filter { selected.contains($0.outpoint) }
        WalletPage {
            if !store.recoveryJobs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Exit queue").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(store.recoveryJobs) { job in
                        NavigationLink(destination: RecoveryStatusView(outpoint: job.outpoint, amount: job.vtxoAmountSat)
                            .environmentObject(store)) {
                            UnilateralExitJobRow(amount: job.vtxoAmountSat,
                                                 status: UnilateralExitStage(status: job.status).title)
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
                    HStack {
                        Text("Choose funds").font(.headline).accessibilityAddTraits(.isHeader)
                        Spacer()
                        let allSelected = selection.count == available.count
                        Button(allSelected ? "Deselect all" : "Select all") {
                            selected = allSelected ? [] : Set(available.map(\.outpoint))
                        }
                        .tint(WalletTheme.action)
                        .accessibilityIdentifier("unilateral.selectAll")
                    }
                    .padding(.bottom, 10)
                    ForEach(available, id: \.outpoint) { fund in
                        let isSelected = selected.contains(fund.outpoint)
                        Button {
                            if isSelected { selected.remove(fund.outpoint) }
                            else { selected.insert(fund.outpoint) }
                        } label: {
                            HStack {
                                Text(WalletFormatting.sats(fund.amountSat))
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? WalletTheme.action : WalletTheme.secondary)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("unilateral.input.\(fund.outpoint)")
                        WalletDivider()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let showsFooter = error == nil && !available.isEmpty
            // Keep the navigation link mounted after the selected funds leave the inventory.
            ExitFooter {
                if !selection.isEmpty {
                    ExitValueLine(label: "Selected (\(selection.count))",
                                  value: WalletFormatting.sats(selection.reduce(0) { $0 + $1.amountSat }))
                }
                NavigationLink(destination: UnilateralExitReviewView(funds: selection)) {
                    Text("Review exit")
                }
                .buttonStyle(WalletButtonStyle())
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("unilateral.review")
            }
            .frame(height: showsFooter ? nil : 0)
            .clipped()
            .accessibilityHidden(!showsFooter)
        }
        .navigationTitle("Unilateral exit").navigationBarTitleDisplayMode(.inline)
        .task { await loadFunds() }
        .refreshable { await loadFunds() }
    }

    private func loadFunds() async {
        error = nil
        do {
            let result = try await store.recoveryFunds()
            try Task.checkCancellation()
            funds = result
            selected.formIntersection(result.map(\.outpoint))
        } catch {
            if !Task.isCancelled { self.error = "Couldn’t load funds for exit." }
        }
    }
}

private struct UnilateralExitReviewView: View {
    @State private var funds: [WalletVTXO]
    @EnvironmentObject private var store: WalletStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var plan: UnilateralExitSelectionPlan?
    @State private var fundingOutpoint: String?
    @State private var checkingPlan = false
    @State private var planError: String?
    @State private var customAddress = false
    @State private var sweepAddress = ""
    @State private var customFeeRate = false
    @State private var feeRateText = ""
    @FocusState private var editingOption: Bool
    @State private var isSubmitting = false
    @State private var attempts: [String: UnilateralExitAdmission] = [:]
    @State private var startError: String?
    @State private var showsQR = false

    init(funds: [WalletVTXO]) {
        // Retain the reviewed selection as each started exit leaves the inventory.
        _funds = State(initialValue: funds)
    }

    private var outpoints: [String] { funds.map(\.outpoint) }
    private var amount: Int64 { funds.reduce(0) { $0 + $1.amountSat } }
    private var options: UnilateralExitOptions? {
        let destination = customAddress ? sweepAddress.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !customAddress || !destination.isEmpty else { return nil }
        let rate = customFeeRate ? Int64(feeRateText) : 0
        guard let rate, !customFeeRate || rate > 0 else { return nil }
        return UnilateralExitOptions(sweepAddress: destination, feeRateSatPerVByte: rate)
    }
    private var quotedPlan: UnilateralExitSelectionPlan? {
        guard let plan, plan.options == options else { return nil }
        return plan
    }
    private var canStart: Bool { !checkingPlan && planError == nil && quotedPlan?.canStart == true }
    private var showsFunding: Bool { fundingOutpoint != nil }
    private var canPollFunding: Bool { showsFunding && scenePhase == .active && !store.isSessionLocked && !isSubmitting }

    private var title: String {
        if !attempts.isEmpty { return funds.count == 1 && !isSubmitting ? "Unilateral exit" : "Exit progress" }
        return showsFunding ? "Fund network fees" : "Review exit"
    }

    var body: some View {
        ZStack {
            if !isSubmitting, let fund = funds.first, funds.count == 1, let admission = attempts[fund.outpoint] {
                RecoveryStatusView(outpoint: fund.outpoint, amount: fund.amountSat, startError: admission.error,
                                   quotedAddress: plan?.sweepAddress)
            } else if !attempts.isEmpty {
                selectionProgress
            } else {
                WalletPage {
                    if showsFunding, let funding = plan?.funding {
                        fundingInstructions(funding)
                    } else {
                        review
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
                .refreshable { await loadPlan() }
            }
        }
        .onChange(of: options) { _ in
            planError = nil
            startError = nil
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task { await loadPlan() }
        .task(id: isSubmitting) {
            if isSubmitting { await submit() }
        }
        .task(id: canPollFunding) {
            guard canPollFunding else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                await loadPlan()
            }
        }
    }

    @ViewBuilder private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(funds.count == 1 ? "Selected to exit" : "Selected to exit · \(funds.count)")
                .foregroundStyle(WalletTheme.secondary)
            WalletAmount(amount: amount)
        }
        .padding(.bottom, 12)
        if canStart {
            WalletStatus(text: "Ready to exit", complete: true)
            if plan?.entries.contains(where: { !$0.roundCommitment.isEmpty }) == true {
                Text("Some selected funds are in an active round. Starting the exit may interrupt it.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
        }
        exitOptions
        if let fee = quotedPlan?.totalEstimatedFeeSat {
            ExitValueLine(label: "Estimated network fees", value: WalletFormatting.sats(fee))
        }
        if let funding = quotedPlan?.funding {
            ExitValueLine(label: "Fee funding needed", value: funding.summary)
            if funds.count > 1 {
                Text("Fund this step first. We’ll recheck the full selection after it confirms.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
        }
        if let plan = quotedPlan {
            ForEach(Array(zip(funds, plan.entries)), id: \.0.outpoint) { fund, entry in
                if !entry.canStart, UnilateralExitFunding(entry) == nil {
                    ExitValueLine(label: WalletFormatting.sats(fund.amountSat), value: blockedMessage(entry))
                }
            }
        }
        if let startError {
            Text(startError).font(.footnote).foregroundStyle(WalletTheme.secondary)
        }
        if checkingPlan || isSubmitting {
            WalletLoadingIndicator(label: isSubmitting ? "Starting exit" : "Checking exit plan")
        } else if let planError {
            Text(planError).font(.footnote).foregroundStyle(WalletTheme.secondary)
        }
    }

    private var exitOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !customAddress {
                ValueRow(label: "To", value: "My on-chain wallet")
            }
            Toggle("Use another Bitcoin address", isOn: $customAddress)
                .accessibilityIdentifier("unilateral.customAddress")
            if customAddress {
                WalletField(title: "To") {
                    TextField("Bitcoin address", text: $sweepAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                        .focused($editingOption)
                        .accessibilityIdentifier("unilateral.address")
                }
            }
            WalletDivider()
            Toggle("Set fee rate", isOn: $customFeeRate)
                .accessibilityIdentifier("unilateral.customFee")
            if customFeeRate {
                WalletField(title: "Fee rate (sat/vB)") {
                    TextField("sat/vB", text: $feeRateText)
                        .keyboardType(.numberPad)
                        .focused($editingOption)
                        .accessibilityIdentifier("unilateral.feeRate")
                }
                Text("The rate applies to new transactions. Package fee bumps can change the total.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            } else if let rate = quotedPlan?.feeRate, rate > 0 {
                ExitValueLine(label: "Estimated fee rate", value: "Automatic · \(rate) sat/vB")
            }
        }
        .disabled(isSubmitting)
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
        if showsFunding, let entry = plan?.fundingEntry {
            ExitFooter {
                WalletStatus(text: planError == nil ? "Waiting for confirmation" : "Couldn’t check funding",
                             pending: planError == nil)
                let usable = min(entry.usableFeeUTXOCount, entry.requiredFeeUTXOCount)
                Text("\(usable) of \(entry.requiredFeeUTXOCount) ready for fees")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
        } else if canStart {
            ExitFooter {
                Text("Once started, an exit can’t be undone.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
                Button(funds.count == 1 ? "Start unilateral exit" : "Start \(funds.count) unilateral exits") {
                    startError = nil
                    isSubmitting = true
                }
                .buttonStyle(WalletButtonStyle())
                .disabled(isSubmitting)
                .accessibilityIdentifier("recovery.confirm")
            }
        } else if quotedPlan?.funding != nil, !checkingPlan, planError == nil {
            ExitFooter {
                Button("Continue to funding") { fundingOutpoint = quotedPlan?.fundingEntry?.outpoint }
                    .buttonStyle(WalletButtonStyle())
            }
        } else if quotedPlan == nil || planError != nil {
            ExitFooter {
                Button("Update estimate") {
                    editingOption = false
                    Task { await loadPlan() }
                }
                .buttonStyle(WalletButtonStyle())
                .disabled(options == nil || checkingPlan || isSubmitting)
                .accessibilityIdentifier("unilateral.updateEstimate")
            }
        }
    }

    private var selectionProgress: some View {
        WalletPage {
            WalletAmount(amount: amount)
            if isSubmitting {
                WalletLoadingIndicator(label: "Starting exits")
            } else if attempts.count < funds.count {
                Text("Some exits weren’t started. Check the results below before trying again.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            if !attempts.isEmpty, let startError {
                Text(startError).font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            ForEach(funds, id: \.outpoint) { fund in
                let job = store.recoveryJobs.first { $0.outpoint == fund.outpoint }
                if let admission = attempts[fund.outpoint] {
                    NavigationLink(destination: RecoveryStatusView(outpoint: fund.outpoint, amount: fund.amountSat,
                                                                   startError: admission.error,
                                                                   quotedAddress: plan?.sweepAddress)) {
                        UnilateralExitJobRow(amount: fund.amountSat,
                                             status: job.map { UnilateralExitStage(status: $0.status).title } ?? admission.title)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                } else {
                    ExitValueLine(label: WalletFormatting.sats(fund.amountSat),
                                  value: isSubmitting ? "Waiting to start" : "Not started")
                }
                WalletDivider()
            }
        }
        .task(id: isSubmitting) {
            if !isSubmitting { await store.refresh() }
        }
        .refreshable { await store.refresh() }
    }

    private func loadPlan(recheckingAfterStart: Bool = false) async {
        guard let options, !outpoints.isEmpty, !checkingPlan, attempts.isEmpty,
              !isSubmitting || recheckingAfterStart else { return }
        checkingPlan = true
        defer { checkingPlan = false }
        do {
            let result = try await store.exitPlan(outpoints: outpoints, options: options)
            try Task.checkCancellation()
            guard options == self.options else { return }
            plan = result
            planError = nil
            if result.fundingEntry?.outpoint != fundingOutpoint { fundingOutpoint = nil }
        } catch {
            guard !Task.isCancelled, options == self.options else { return }
            let message = error.walletMessage
            if let validation = ["Enter a valid Bitcoin address", "Use a standard Bitcoin address", "fee rate must be"]
                .first(where: { message.contains($0) }), let range = message.range(of: validation) {
                planError = String(message[range.lowerBound...])
            } else {
                planError = "Couldn’t check the exit plan. Try again."
            }
        }
    }

    private func blockedMessage(_ entry: ExitPlanEntry) -> String {
        if entry.exitJobFound { return "Exit already started" }
        if !entry.roundCommitment.isEmpty { return "In an active round" }
        switch entry.infeasibilityReason {
        case "sweep_below_dust": return "Too small at the current fee"
        case "uneconomical": return "Estimated fees are too high"
        default: return "Can’t start right now"
        }
    }

    private func submit() async {
        defer { isSubmitting = false }
        guard let plan = quotedPlan else { return }
        do {
            try await store.startUnilateralExits(outpoints: outpoints, options: plan.options,
                                                 reviewedFeeRate: plan.feeRate) { outpoint, admission in
                attempts[outpoint] = admission
            }
        } catch {
            if !Task.isCancelled { startError = error.walletMessage }
        }
        if attempts.isEmpty, !Task.isCancelled {
            await loadPlan(recheckingAfterStart: true)
        }
    }
}

private struct UnilateralExitJobRow: View {
    let amount: Int64
    let status: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(WalletFormatting.sats(amount))
                Text(status).font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(WalletTheme.secondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

struct UnilateralExitOptions: Equatable, Sendable {
    var sweepAddress = ""
    var feeRateSatPerVByte: Int64 = 0
}

struct UnilateralExitSelectionPlan {
    let entries: [ExitPlanEntry]
    let options: UnilateralExitOptions
    let sweepAddress: String?
    let feeRate: Int64?
    let totalEstimatedFeeSat: Int64?
    let canStart: Bool

    init(plan: ExitPlan, outpoints: [String], options: UnilateralExitOptions) throws {
        guard !outpoints.isEmpty, let entries = plan.plans,
              entries.map(\.outpoint) == outpoints else {
            throw WalletActionError(message: "Couldn’t verify the selected funds.")
        }
        let address = plan.sweepAddress ?? ""
        let isBech32 = ["bc1", "tb1", "bcrt1", "sb1"].contains { options.sweepAddress.lowercased().hasPrefix($0) }
        let addressMatches = isBech32
            ? address.lowercased() == options.sweepAddress.lowercased()
            : address == options.sweepAddress
        guard addressMatches,
              options.feeRateSatPerVByte == 0 ||
                (plan.feeRateSatPerVByte == options.feeRateSatPerVByte && plan.totalEstimatedFeeSat != nil) else {
            throw WalletActionError(message: "The wallet did not confirm the custom exit options.")
        }
        self.entries = entries
        self.options = options
        sweepAddress = address.isEmpty ? nil : address
        totalEstimatedFeeSat = plan.totalEstimatedFeeSat
        feeRate = plan.feeRateSatPerVByte
        canStart = plan.canStart && entries.allSatisfy { $0.canStart && !$0.exitJobFound && $0.error.isEmpty }
    }

    var fundingEntry: ExitPlanEntry? {
        let blocked = entries.filter { !$0.canStart || $0.exitJobFound || !$0.error.isEmpty }
        guard blocked.allSatisfy({ UnilateralExitFunding($0) != nil }) else { return nil }
        return blocked.first
    }

    var funding: UnilateralExitFunding? { fundingEntry.flatMap(UnilateralExitFunding.init) }
}

enum UnilateralExitAdmission {
    case starting, started, unconfirmed(String)

    var title: String {
        switch self {
        case .starting: return "Starting"
        case .started: return "Started"
        case .unconfirmed: return "Check exit status"
        }
    }

    var error: String? {
        if case .unconfirmed(let message) = self { return message }
        return nil
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
