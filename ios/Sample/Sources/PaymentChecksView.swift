import SwiftUI

/// Retains references after an explicit decision to prepare a separate payment.
/// These are unresolved attempts, not extra accounting rows or confirmed sends.
struct PaymentChecksView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        WalletPage {
            Text("These attempts may still complete.").foregroundStyle(WalletTheme.secondary)
            ForEach(store.unresolvedDispatches) { attempt in
                WalletAmount(amount: attempt.amountSat)
                WalletStatus(text: "Unconfirmed")
                if let date = attempt.startedAt { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                if let error = attempt.error { Text(error).font(.footnote).foregroundStyle(WalletTheme.secondary) }
                DisclosureGroup("Details") {
                    ValueRow(label: "Payment reference", value: attempt.intentID, copyable: true)
                    if !attempt.paymentHash.isEmpty { ValueRow(label: "Payment hash", value: attempt.paymentHash, copyable: true) }
                }
                WalletDivider()
            }
            ForEach(store.unresolvedSweeps) { attempt in
                WalletAmount(amount: attempt.amountSat)
                WalletStatus(text: "Unconfirmed")
                if let date = attempt.startedAt { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                if let error = attempt.error { Text(error).font(.footnote).foregroundStyle(WalletTheme.secondary) }
                ValueRow(label: "Destination", value: attempt.destination, copyable: true)
                if let url = store.addressExplorerURL(address: attempt.destination) { Link("Check destination", destination: url) }
                WalletDivider()
            }
        }.navigationTitle("Payment checks").navigationBarTitleDisplayMode(.inline)
    }
}
