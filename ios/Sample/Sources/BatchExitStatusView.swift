import SwiftUI
import WalletKit

struct BatchExitStatusView: View {
    @EnvironmentObject private var store: WalletStore
    let operationID: UUID
    private var operation: BatchExitOperation? { store.exitBatches.first { $0.id == operationID } }

    var body: some View {
        WalletPage {
            if let operation {
                WalletAmount(amount: operation.amountSat)
                ForEach(operation.inputs) { input in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(WalletFormatting.sats(input.amountSat))
                            Text(shortOutpoint(input.outpoint)).font(.caption.monospaced())
                                .foregroundStyle(WalletTheme.secondary)
                        }
                        Spacer()
                        WalletStatus(text: input.state.title, pending: input.state.isPending,
                                     complete: input.state == .complete, failed: input.state == .failed)
                    }
                    if !input.message.isEmpty {
                        Text(input.message).font(.footnote).foregroundStyle(WalletTheme.secondary)
                    }
                    WalletDivider()
                }
                if operation.inputs.contains(where: { $0.state == .checking }) {
                    Text("The result isn’t confirmed yet. Check status before trying these funds again.")
                        .font(.footnote).foregroundStyle(WalletTheme.secondary)
                }
                Button("Check status") { Task { await store.refresh() } }
                    .buttonStyle(WalletButtonStyle(secondary: true))
                DisclosureGroup("Details") {
                    if let activityID = operation.activityID,
                       let entry = store.activityEntry(id: activityID) {
                        NavigationLink("View activity", destination: ActivityDetailView(entry: entry))
                    }
                    if !operation.destination.isEmpty {
                        ValueRow(label: "To", value: operation.destination, copyable: true)
                    }
                    ForEach(operation.inputs) { input in
                        ValueRow(label: WalletFormatting.sats(input.amountSat), value: input.outpoint, copyable: true)
                    }
                    if let error = operation.error { Text(error).font(.footnote).foregroundStyle(WalletTheme.secondary) }
                }
                if let message = store.exitBatchJournalError { Text(message).font(.footnote).foregroundStyle(.red) }
            }
        }.navigationTitle("Cooperative exit").navigationBarTitleDisplayMode(.inline)
            .task { await store.refresh() }
    }
}

private func shortOutpoint(_ outpoint: String) -> String {
    guard let colon = outpoint.lastIndex(of: ":") else { return outpoint }
    return String(outpoint[..<colon].prefix(8)) + "…" + outpoint[colon...]
}
