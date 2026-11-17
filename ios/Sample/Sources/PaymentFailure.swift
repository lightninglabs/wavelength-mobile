import Foundation
import SwiftUI

/// Presentation only. Native errors still own payment state and retry decisions.
enum PaymentFailure {
    static func message(_ raw: String) -> String {
        let reason = raw.lowercased()
        if reason.contains("maximum payment quote changed") {
            return "The quote changed. Calculate the available balance again."
        }
        if reason.contains("change below minimum vtxo amount") ||
            reason.contains("selection change below minimum") {
            return "This amount would leave too little change. Request a different amount or add funds."
        }
        if reason.contains("insufficient spendable funds") || reason.contains("insufficient funds") {
            return "There isn’t enough available balance to cover this payment and its fees."
        }
        if reason.contains("rpc error:") {
            if reason.contains("invoice already paid") || reason.contains("invoice has already been paid") {
                return "This invoice has already been paid. Ask the recipient for a new invoice."
            }
            if reason.contains("invoice has expired") || reason.contains("invoice is expired") {
                return "This invoice has expired. Ask the recipient for a new invoice."
            }
            if reason.contains("code = deadlineexceeded") || reason.contains("code = canceled") {
                return "The request ended before its result could be confirmed. Check Activity before trying again."
            }
            if reason.contains("code = unavailable") {
                return "The payment service is unavailable. Check your connection and Activity before trying again."
            }
            if reason.contains("code = invalidargument") || reason.contains("code = failedprecondition") ||
                reason.contains("code = outofrange") {
                return "The request couldn’t be processed. Review the invoice, amount and fees."
            }
            return "The request couldn’t be completed. Check Activity before trying again."
        }
        return raw
    }

    /// Keep the original error copyable without exposing transport details first.
    static func technicalDetails(_ raw: String) -> String? {
        message(raw) == raw ? nil : raw
    }
}

struct PaymentErrorSheet: View {
    let title: String
    @State private var message: String
    @Environment(\.presentationMode) private var presentationMode
    @State private var showsDetails = false

    init(title: String, message: String) {
        self.title = title
        // The parent clears its error on dismissal. Keep this presentation's
        // evidence stable until the sheet finishes animating away.
        _message = State(initialValue: message)
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.medium, .large])
        } else {
            content
        }
    }

    private var content: some View {
        NavigationView {
            WalletPage {
                Text(PaymentFailure.message(message))
                    .accessibilityIdentifier("payment.error.message")
                if let detail = PaymentFailure.technicalDetails(message) {
                    DisclosureGroup("Technical details", isExpanded: $showsDetails) {
                        ValueRow(label: "Error", value: detail, copyable: true)
                            .padding(.top, 12)
                    }
                    .accessibilityIdentifier("payment.error.details")
                }
                Button("Done") { presentationMode.wrappedValue.dismiss() }
                    .buttonStyle(WalletButtonStyle())
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }
}
