import SwiftUI
import WalletKit

struct UnilateralExitReviewView: View {
    @State private var funds: [WalletVTXO]
    @EnvironmentObject private var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var options = UnilateralExitOptions()
    @State private var quote: UnilateralExitQuote?
    @State private var quoteRequest = UUID()
    @State private var isQuoting = true
    @State private var quoteError: String?
    @State private var actionMessage: String?
    @State private var fundingStep: FundingStep?
    @State private var isChecking = false
    @State private var isRecheckingFunding = false
    @State private var action: ReviewAction?
    @State private var readyRate: Int64?
    @State private var attempts: [String: UnilateralExitAdmission] = [:]
    @State private var showsQR = false

    init(funds: [WalletVTXO]) {
        // Retain the reviewed selection as admitted exits leave the inventory.
        _funds = State(initialValue: funds)
    }

    private struct QuoteScope: Equatable {
        let options: UnilateralExitOptions
        let isFunding: Bool
    }

    private enum ReviewAction: Equatable { case checkAndStart, checkFunding }

    private struct FundingStep {
        let outpoint: String
        let funding: UnilateralExitFunding
    }

    private var outpoints: [String] { funds.map(\.outpoint) }
    private var amount: Int64 { funds.reduce(0) { $0 + $1.amountSat } }
    private var currentQuote: UnilateralExitQuote? { quote?.options == options ? quote : nil }
    private var canPollFunding: Bool {
        fundingStep != nil && scenePhase == .active && !store.isSessionLocked
    }

    var body: some View {
        Group {
            if !attempts.isEmpty {
                UnilateralExitSelectionProgress(funds: funds, attempts: attempts,
                    destination: options.sweepAddress, isStarting: isChecking)
            } else {
                WalletPage {
                    if let fundingStep {
                        fundingInstructions(fundingStep)
                    } else {
                        VStack(alignment: .leading, spacing: 15) { review }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
                .refreshable {
                    if let fundingStep { await recheckFunding(fundingStep) }
                    else { await loadQuote() }
                }
            }
        }
        .navigationTitle(fundingStep == nil ? attempts.isEmpty ? "Review exit" : "Exit progress" : "Fund network fees")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: QuoteScope(options: options, isFunding: fundingStep != nil)) {
            if fundingStep == nil { await loadQuote() }
        }
        .onChange(of: options) { _ in
            actionMessage = nil
            readyRate = nil
        }
        .task(id: action) {
            if let action { await check(action) }
        }
        .task(id: canPollFunding) {
            guard canPollFunding else { return }
            while !Task.isCancelled, let fundingStep {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                await recheckFunding(fundingStep)
            }
        }
    }

    @ViewBuilder private var review: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Total selected · \(funds.count) \(funds.count == 1 ? "fund" : "funds")")
                .foregroundStyle(WalletTheme.secondary)
            WalletAmount(amount: amount)
        }
        .padding(.bottom, 12)

        NavigationLink {
            UnilateralExitDestinationEditor(address: $options.sweepAddress)
        } label: {
            ExitSettingsRow(label: "To", value: destinationLabel)
        }
        .buttonStyle(.plain)
        .disabled(isChecking)
        .accessibilityIdentifier("unilateral.customAddress")
        WalletDivider()

        if let currentQuote, !isQuoting, quoteError == nil {
            estimate(currentQuote)
        } else {
            feeRateRow
        }

        if isQuoting || isChecking {
            WalletLoadingIndicator(label: isChecking ? "Checking exit readiness" : "Checking exit estimate")
        } else if let quoteError {
            Text(quoteError).font(.footnote).foregroundStyle(WalletTheme.secondary)
        }
        if let actionMessage {
            Text(actionMessage).font(.footnote).foregroundStyle(WalletTheme.secondary)
        }
    }

    @ViewBuilder private func estimate(_ quote: UnilateralExitQuote) -> some View {
        if quote.preview.estimatedTransactions > 0 {
            Text(quote.blocked.isEmpty ? "Exit estimate" : "Estimate for eligible funds")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ExitValueLine(label: "Network fees", value: WalletFormatting.sats(quote.preview.estimatedNetworkFeeSat))
                .accessibilityIdentifier("unilateral.networkFees")
            WalletDivider()
            ExitValueLine(label: "Paid from on-chain wallet", value: WalletFormatting.sats(quote.preview.walletFeeSat))
            WalletDivider()
        }

        feeRateRow

        if quote.blocked.isEmpty {
            WalletDivider()
            ExitValueLine(label: "Bitcoin transactions", value: "About \(quote.preview.estimatedTransactions)")
            WalletDivider()
            if quote.needsFunding {
                ExitValueLine(label: "Estimated extra funding",
                              value: WalletFormatting.sats(quote.preview.additionalFundingSat))
                    .accessibilityIdentifier("unilateral.extraFunding")
                Text("Confirm the funding requirements before sending bitcoin.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            } else {
                Label("No extra funding estimated", systemImage: "checkmark")
                    .font(.subheadline).foregroundStyle(WalletTheme.secondary)
                Text(quote.preview.fundingAction == "reuse_confirmed_change"
                     ? "The wallet may wait for change to confirm."
                     : "The wallet checks readiness before starting.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            if options.feeRateSatPerVByte == 0 {
                Text("The wallet sets the fee rate when each exit starts.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            if quote.preview.entries.contains(where: { !$0.roundCommitment.isEmpty }) {
                Text("Some selected funds are in an active round.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
        } else {
            Label(quote.economicBlock ? "Exit unavailable at this fee rate" : "Some funds can’t be started",
                  systemImage: "exclamationmark.triangle")
                .font(.headline)
            if quote.allUneconomical {
                Text("Fees would use up the selected funds.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            } else {
                ForEach(quote.blocked, id: \.outpoint) { entry in
                    let amount = funds.first { $0.outpoint == entry.outpoint }?.amountSat ?? entry.amountSat
                    ExitValueLine(label: WalletFormatting.sats(amount), value: quote.blockedMessage(entry))
                }
            }
        }
    }

    private var feeRateRow: some View {
        NavigationLink {
            UnilateralExitFeeEditor(rate: $options.feeRateSatPerVByte,
                                    automaticRate: options.feeRateSatPerVByte == 0 ? currentQuote?.rate : nil)
        } label: {
            ExitSettingsRow(label: "Fee rate", value: feeRateLabel)
        }
        .buttonStyle(.plain)
        .disabled(isChecking)
        .accessibilityIdentifier("unilateral.customFee")
    }

    private var feeRateLabel: String {
        if options.feeRateSatPerVByte > 0 { return "\(options.feeRateSatPerVByte) sat/vB" }
        if let rate = currentQuote?.rate { return "Automatic · \(rate) sat/vB" }
        return "Automatic"
    }

    private var destinationLabel: String {
        let address = options.sweepAddress
        guard !address.isEmpty else { return "My on-chain wallet" }
        return address.count > 21 ? "\(address.prefix(11))…\(address.suffix(8))" : address
    }

    private func fundingInstructions(_ step: FundingStep) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add funds for fees").font(.title2.weight(.medium))
            if funds.count > 1 {
                Text("This funds the next exit. The wallet will recheck the rest after confirmation.")
                    .foregroundStyle(WalletTheme.secondary)
            }
            Text(step.funding.instructions)
            ValueRow(label: "Fee funding address", value: step.funding.address, copyable: true)
            Button(showsQR ? "Hide QR" : "Show QR") { showsQR.toggle() }
            if showsQR {
                QRCodeView(value: step.funding.address)
                    .frame(width: 210, height: 210)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity)
            }
            Text("Wait for these payments to confirm before sending more.")
                .font(.footnote).foregroundStyle(WalletTheme.secondary)
            if let actionMessage {
                Text(actionMessage).font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if fundingStep != nil {
            ExitFooter {
                WalletStatus(text: actionMessage == nil ? "Waiting for confirmation" : "Funding status unavailable",
                             pending: actionMessage == nil)
            }
        } else if let currentQuote, quoteError == nil, !isQuoting {
            ExitFooter {
                if !currentQuote.blocked.isEmpty {
                    Button("Change selection") { dismiss() }
                        .buttonStyle(WalletButtonStyle())
                } else {
                    let mustCheckFunding = currentQuote.needsFunding && readyRate != currentQuote.rate
                    Button(mustCheckFunding ? "Check funding requirements" : "Check and start") {
                        action = mustCheckFunding ? .checkFunding : .checkAndStart
                        isChecking = true
                    }
                    .buttonStyle(WalletButtonStyle())
                    .disabled(isChecking)
                    .accessibilityIdentifier("recovery.confirm")
                }
            }
        } else if quoteError != nil {
            ExitFooter {
                Button("Try again") { Task { await loadQuote() } }
                    .buttonStyle(WalletButtonStyle())
                    .disabled(isQuoting || isChecking)
            }
        }
    }

    private func loadQuote() async {
        guard attempts.isEmpty, fundingStep == nil else { return }
        let requestedOptions = options
        let request = UUID()
        quoteRequest = request
        isQuoting = true
        quoteError = nil
        defer { if quoteRequest == request { isQuoting = false } }
        do {
            let result = try await store.previewUnilateralExit(outpoints: outpoints, options: requestedOptions)
            try Task.checkCancellation()
            guard quoteRequest == request, options == requestedOptions else { return }
            quote = result
        } catch {
            guard !Task.isCancelled, quoteRequest == request, options == requestedOptions else { return }
            quote = nil
            quoteError = validationMessage(error)
        }
    }

    private func check(_ action: ReviewAction) async {
        defer {
            isChecking = false
            self.action = nil
        }
        guard let quote = currentQuote, quote.blocked.isEmpty else { return }
        actionMessage = nil
        readyRate = nil
        do {
            let plan = try await store.exitPlan(outpoints: outpoints, options: options)
            try Task.checkCancellation()
            guard plan.feeRate == quote.rate else {
                actionMessage = "The fee rate changed. Review the updated estimate."
                await loadQuote()
                return
            }
            if let entry = plan.fundingEntry, let funding = plan.funding {
                showsQR = false
                fundingStep = FundingStep(outpoint: entry.outpoint, funding: funding)
            } else if !plan.canStart {
                actionMessage = "The wallet can’t start these exits yet. Review the selected funds and try again."
                await loadQuote()
            } else if action == .checkFunding {
                readyRate = plan.feeRate
                actionMessage = "Funding is ready. Review the updated estimate to start."
                await loadQuote()
            } else {
                try await store.startUnilateralExits(outpoints: outpoints, options: options,
                                                     reviewedFeeRate: quote.rate) { outpoint, admission in
                    attempts[outpoint] = admission
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            actionMessage = validationMessage(error)
            await loadQuote()
        }
    }

    private func recheckFunding(_ step: FundingStep) async {
        guard !isRecheckingFunding else { return }
        isRecheckingFunding = true
        defer { isRecheckingFunding = false }
        let requestedOptions = options
        do {
            let plan = try await store.exitPlan(outpoints: outpoints, options: requestedOptions)
            try Task.checkCancellation()
            guard fundingStep?.outpoint == step.outpoint, options == requestedOptions else { return }
            actionMessage = nil
            if plan.canStart || plan.fundingEntry?.outpoint != step.outpoint {
                quote = nil
                isQuoting = true
                fundingStep = nil
                readyRate = plan.canStart ? plan.feeRate : nil
                actionMessage = plan.canStart ? "Funding confirmed. Review the exit to start."
                    : "Funding requirements changed. Review the updated estimate."
            }
        } catch {
            guard !Task.isCancelled, fundingStep?.outpoint == step.outpoint else { return }
            actionMessage = "Couldn’t check funding. We’ll try again."
        }
    }

    private func validationMessage(_ error: Error) -> String {
        let message = error.walletMessage
        let validation = ["Enter a valid Bitcoin address", "Use a standard Bitcoin address",
                          "fee rate must be", "The exit plan changed", "The wallet is busy",
                          "Couldn’t verify the selected funds", "The wallet did not confirm the custom exit options"]
        if let prefix = validation.first(where: { message.contains($0) }),
           let range = message.range(of: prefix) {
            return String(message[range.lowerBound...])
        }
        return "Couldn’t check the exit plan. Try again."
    }
}
