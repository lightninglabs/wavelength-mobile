import SwiftUI
import WalletKit

struct UnilateralExitView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var funds: [WalletVTXO]?
    @State private var selected: Set<String> = []
    @State private var error: String?

    private let selectionLimit = 100

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
                        let limit = min(available.count, selectionLimit)
                        let allSelected = selection.count == limit
                        let selectLabel = available.count > limit ? "Select \(limit)" : "Select all"
                        Button(allSelected ? "Deselect all" : selectLabel) {
                            selected = allSelected ? [] : Set(available.prefix(limit).map(\.outpoint))
                        }
                        .tint(WalletTheme.action)
                        .accessibilityIdentifier("unilateral.selectAll")
                    }
                    .padding(.bottom, 10)
                    ForEach(available, id: \.outpoint) { fund in
                        let isSelected = selected.contains(fund.outpoint)
                        Button {
                            if isSelected { selected.remove(fund.outpoint) }
                            else if selection.count < selectionLimit { selected.insert(fund.outpoint) }
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
                        .disabled(!isSelected && selection.count >= selectionLimit)
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

struct ExitFooter<Content: View>: View {
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

struct ExitValueLine: View {
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
