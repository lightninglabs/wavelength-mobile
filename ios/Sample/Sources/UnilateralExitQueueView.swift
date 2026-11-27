import SwiftUI
import WalletKit

struct UnilateralExitSelectionProgress: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.scenePhase) private var scenePhase
    let funds: [WalletVTXO]
    let attempts: [String: UnilateralExitAdmission]
    let destination: String
    let isStarting: Bool
    @State private var stages: [String: UnilateralExitStage] = [:]

    private var canPoll: Bool { !isStarting && scenePhase == .active && !store.isSessionLocked }
    private var admitted: [WalletVTXO] {
        funds.filter { fund in
            if stages[fund.outpoint] != nil { return true }
            if case .started? = attempts[fund.outpoint] { return true }
            return false
        }
    }

    var body: some View {
        WalletPage {
            if !admitted.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Total exiting · \(admitted.count) \(admitted.count == 1 ? "fund" : "funds")")
                        .foregroundStyle(WalletTheme.secondary)
                    WalletAmount(amount: admitted.reduce(0) { $0 + $1.amountSat })
                    Text("\(stages.values.filter { $0 == .complete }.count) of \(admitted.count) complete")
                        .foregroundStyle(WalletTheme.secondary)
                }
            }
            if isStarting {
                WalletLoadingIndicator(label: "Starting exits")
            } else if admitted.count < funds.count {
                Text("Check which exits started before trying again.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Exit queue").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(funds, id: \.outpoint) { fund in
                    if let admission = attempts[fund.outpoint] {
                        NavigationLink(destination: RecoveryStatusView(outpoint: fund.outpoint, amount: fund.amountSat,
                                                                       startError: admission.error,
                                                                       quotedAddress: destination.isEmpty ? nil : destination)) {
                            UnilateralExitJobRow(amount: fund.amountSat,
                                status: stages[fund.outpoint]?.queueTitle ?? admission.title, stage: stages[fund.outpoint])
                        }
                        .buttonStyle(.plain)
                        .disabled(isStarting)
                    } else {
                        ExitValueLine(label: WalletFormatting.sats(fund.amountSat),
                                      value: isStarting ? "Waiting to start" : "Not started")
                    }
                    WalletDivider()
                }
            }
            ValueRow(label: "To", value: destination.isEmpty ? "My on-chain wallet" : destination,
                     copyable: !destination.isEmpty)
        }
        .task(id: canPoll) {
            guard canPoll else { return }
            while !Task.isCancelled {
                await refreshStages()
                if attempts.keys.allSatisfy({ stages[$0]?.isTerminal == true }) { return }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
            }
        }
        .task(id: canPoll) {
            if canPoll { await store.refresh() }
        }
        .refreshable { if canPoll { await refreshStages() } }
    }

    private func refreshStages() async {
        for fund in funds where attempts[fund.outpoint] != nil && stages[fund.outpoint]?.isTerminal != true {
            do {
                let status = try await store.recoveryStatus(outpoint: fund.outpoint)
                try Task.checkCancellation()
                if status.found { stages[fund.outpoint] = UnilateralExitStage(status: status.status) }
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
    }
}

struct UnilateralExitJobRow: View {
    let amount: Int64
    let status: String
    var stage: UnilateralExitStage? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(WalletFormatting.sats(amount))
                HStack(spacing: 7) {
                    if let stage {
                        Image(systemName: stage == .complete ? "checkmark.circle.fill" :
                                stage == .failed ? "exclamationmark.circle" :
                                stage == .publishing ? "circle" : "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(stage == .complete ? WalletTheme.action :
                                                stage == .failed ? Color.red :
                                                stage == .waiting || stage == .sweeping ? Color.orange : WalletTheme.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(status).font(.footnote).foregroundStyle(WalletTheme.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(WalletTheme.secondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}
