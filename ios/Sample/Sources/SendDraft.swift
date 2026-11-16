import Foundation

/// The complete input that produced a review. Any edit requires a new quote.
struct SendDraft: Equatable {
    let destination: String
    let amount: String
    let note: String
    let maxFee: String
    let sweepAll: Bool
    let network: String
}

enum SendAmount {
    /// Old services have no capability field and reject a missing signed amount.
    static func prepareError(_ message: String, amountlessInvoice: Bool) -> String {
        guard amountlessInvoice, message.contains("invoice amount is required") else { return message }
        return "This payment service does not support invoices without an amount yet. Ask the recipient for an invoice with an amount."
    }

    /// Accept whole sats only. Pasted signs, fractions and overflow stay invalid.
    static func satoshis(_ text: String) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let amount = Int64(text), amount > 0, amount <= 2_100_000_000_000_000 else { return nil }
        return amount
    }
}
