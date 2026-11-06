import Foundation

/// Normalizes QR-code and clipboard payment payloads into destinations accepted
/// by Wavelength's prepare-send API.
public enum PaymentRequestParser {
    /// Returns a BOLT-11 invoice or Bitcoin address from a raw payment payload.
    /// BIP-21 requests containing a `lightning` parameter prefer that invoice;
    /// otherwise their on-chain address is returned without query parameters.
    public static func normalizedDestination(from payload: String) -> String {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard let separator = trimmed.firstIndex(of: ":") else {
            return trimmed
        }

        let scheme = trimmed[..<separator].lowercased()
        let remainderStart = trimmed.index(after: separator)
        let remainder = String(trimmed[remainderStart...])

        switch scheme {
        case "lightning":
            return decoded(remainder.removingLeadingDoubleSlash)

        case "bitcoin":
            if let components = URLComponents(string: trimmed),
               let invoice = components.queryItems?.first(where: {
                   $0.name.caseInsensitiveCompare("lightning") == .orderedSame
               })?.value,
               !invoice.isEmpty {

                return normalizedDestination(from: invoice)
            }

            let address = remainder.removingLeadingDoubleSlash
                .components(separatedBy: "?").first ?? remainder
            return decoded(address)

        default:
            return trimmed
        }
    }

    private static func decoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}

private extension String {
    var removingLeadingDoubleSlash: String {
        hasPrefix("//") ? String(dropFirst(2)) : self
    }
}
