import SwiftUI
import WalletKit

struct RecoveryStatusView: View {
    let outpoint: String
    let amount: Int64
    var startError: String?
    var quotedAddress: String?
    @EnvironmentObject private var store: WalletStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: ExitStatusResult?
    @State private var checkFailed = false
    @State private var checkingStatus = false

    private var stage: UnilateralExitStage { UnilateralExitStage(status: status?.status) }
    private var canCheck: Bool { scenePhase == .active && !store.isSessionLocked }

    private var destination: String? {
        if status?.found != true { return quotedAddress }
        return status?.sweepAddress.flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        WalletPage {
            VStack(alignment: .leading, spacing: 12) {
                if stage == .complete, let fees = status?.fees, fees.sweepFeeActual {
                    Text(destination == nil ? "Received on-chain" : "Sent on-chain").foregroundStyle(WalletTheme.secondary)
                    WalletAmount(amount: fees.netRecoveredSat)
                } else {
                    Text("Selected to exit").foregroundStyle(WalletTheme.secondary)
                    WalletAmount(amount: amount)
                }
                WalletStatus(text: statusTitle, pending: !stage.isTerminal && (status?.found == true || startError == nil) && !checkFailed,
                             complete: stage == .complete, failed: stage == .failed)
                if stage == .publishing, let progress = status?.progress, progress.totalTxs > 0 {
                    Text("\(progress.confirmedTxs) of \(progress.totalTxs) confirmed")
                        .font(.subheadline).foregroundStyle(WalletTheme.secondary)
                }
                if stage == .waiting, let csv = status?.csv, csv.blocksRemaining > 0 {
                    Text("\(csv.blocksRemaining) blocks left")
                        .font(.subheadline).foregroundStyle(WalletTheme.secondary)
                }
            }
            ValueRow(label: "To", value: destination ?? "My on-chain wallet", copyable: destination != nil)
            if let fees = status?.fees {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Network fees").font(.headline)
                    ValueRow(label: "Estimated fees so far", value: WalletFormatting.sats(fees.spentSoFarSat))
                    ValueRow(label: "Estimated total", value: WalletFormatting.sats(fees.totalCostSat))
                }
            }
            if status?.found == true {
                NavigationLink(destination: UnilateralExitProgressView(status: $status, watchStatus: watchStatus)
                    .environmentObject(store)) {
                    WalletNavigationRow(title: "Exit progress", icon: "list.bullet")
                }.buttonStyle(.plain)
            }
            if let txid = status?.sweepTxid, !txid.isEmpty, stage == .sweeping || stage == .complete,
               let url = store.transactionExplorerURL(txid: txid) {
                Link(destination: url) {
                    WalletNavigationRow(title: "View sweep transaction", icon: "arrow.up.right.square")
                }.buttonStyle(.plain)
            }
            if stage == .complete, destination == nil {
                NavigationLink("Send on-chain funds", destination: SweepWalletView())
            }
            if stage == .failed, let error = status?.lastError, !error.isEmpty {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if checkFailed {
                Text("Couldn’t update exit status.").font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            DisclosureGroup("Details") {
                ValueRow(label: "Outpoint", value: outpoint, copyable: true).padding(.vertical, 8)
                if let txid = status?.sweepTxid, !txid.isEmpty {
                    ValueRow(label: "Sweep transaction ID", value: txid, copyable: true)
                }
                if let error = status?.lastError, !error.isEmpty {
                    ValueRow(label: "Exit error", value: error, copyable: true)
                } else if status?.found != true, let startError {
                    ValueRow(label: "Exit error", value: startError, copyable: true)
                }
            }
        }
        .navigationTitle("Unilateral exit").navigationBarTitleDisplayMode(.inline)
        .task(id: canCheck) {
            if canCheck { await watchStatus() }
        }
        .refreshable { await checkStatus() }
    }

    private var statusTitle: String {
        if status?.found != true, startError != nil { return "Couldn’t confirm the exit started" }
        return stage.title
    }

    private func checkStatus() async {
        guard !checkingStatus else { return }
        checkingStatus = true
        defer { checkingStatus = false }
        do {
            let result = try await store.recoveryStatus(outpoint: outpoint)
            try Task.checkCancellation()
            status = result
            checkFailed = false
        } catch {
            if !Task.isCancelled { checkFailed = true }
        }
    }

    private func watchStatus() async {
        repeat {
            await checkStatus()
            if stage.isTerminal { return }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
        } while !Task.isCancelled
    }
}

private struct UnilateralExitProgressView: View {
    @Binding var status: ExitStatusResult?
    let watchStatus: () async -> Void
    @EnvironmentObject private var store: WalletStore
    @Environment(\.scenePhase) private var scenePhase

    private var stage: UnilateralExitStage { UnilateralExitStage(status: status?.status) }
    private var canCheck: Bool { scenePhase == .active && !store.isSessionLocked }

    var body: some View {
        WalletPage {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Step.allCases, id: \.self) { step in
                    stepRow(step)
                }
            }
        }
        .navigationTitle("Exit progress").navigationBarTitleDisplayMode(.inline)
        .task(id: canCheck) {
            if canCheck { await watchStatus() }
        }
    }

    private func stepRow(_ step: Step) -> some View {
        let state = step.state(at: stage)
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: state.icon)
                    .frame(height: 22)
                    .foregroundStyle(state == .pending ? WalletTheme.secondary : WalletTheme.action)
                if step != .sweep {
                    Rectangle().fill(WalletTheme.line).frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 22)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(step.title).font(.body.weight(.medium))
                Text(detail(for: step, state: state))
                    .font(.subheadline).foregroundStyle(WalletTheme.secondary)
            }
            .padding(.bottom, step == .sweep ? 0 : 22)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func detail(for step: Step, state: Step.State) -> String {
        if step == .publish, let progress = status?.progress, progress.totalTxs > 0 {
            return "\(progress.confirmedTxs) of \(progress.totalTxs) confirmed"
        }
        if step == .wait, stage == .waiting, let csv = status?.csv, csv.blocksRemaining > 0 {
            return "\(csv.blocksRemaining) blocks left"
        }
        switch state {
        case .done: return "Complete"
        case .active: return "In progress"
        case .pending: return stage == .failed ? "Exit stopped" : "Pending"
        }
    }

    private enum Step: CaseIterable {
        case publish, wait, sweep

        enum State {
            case pending, active, done

            var icon: String {
                switch self {
                case .pending: return "circle"
                case .active: return "circle.inset.filled"
                case .done: return "checkmark.circle.fill"
                }
            }
        }

        var title: String {
            switch self {
            case .publish: return "Publish exit transactions"
            case .wait: return "Wait for block delay"
            case .sweep: return "Publish final sweep"
            }
        }

        func state(at stage: UnilateralExitStage) -> State {
            if stage == .complete { return .done }
            switch (self, stage) {
            case (.publish, .publishing), (.wait, .waiting), (.sweep, .sweeping): return .active
            case (.publish, .waiting), (.publish, .sweeping), (.wait, .sweeping): return .done
            default: return .pending
            }
        }
    }
}
