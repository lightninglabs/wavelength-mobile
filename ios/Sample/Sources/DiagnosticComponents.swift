import SwiftUI
import UIKit
import WalletKit

struct DiagnosticShare: Identifiable {
    let id = UUID()
    let text: String
}

struct DiagnosticShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DiagnosticIdentifier: View {
    let label: String
    let value: String
    @State private var share: DiagnosticShare?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).foregroundStyle(WalletTheme.secondary)
                Spacer()
                CopyButton(value: value)
                Button { share = DiagnosticShare(text: value) } label: {
                    Image(systemName: "square.and.arrow.up")
                }.accessibilityLabel("Share \(label)")
            }
            Text(value).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $share) { DiagnosticShareSheet(text: $0.text) }
    }
}

struct DiagnosticRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(WalletTheme.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct DiagnosticRaw: View {
    let value: DiagnosticValue
    var body: some View {
        DisclosureGroup("Raw response") {
            VStack(alignment: .leading, spacing: 12) {
                CopyButton(value: value.pretty)
                Text(value.pretty).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.top, 12)
        }
    }
}

struct DiagnosticFailure: View {
    let message: String?
    var body: some View {
        if let message {
            Text(message).font(.footnote).foregroundStyle(WalletTheme.secondary)
                .accessibilityIdentifier("diagnostics.error")
        }
    }
}

func diagnosticShort(_ text: String) -> String {
    text.count > 24 ? String(text.prefix(12)) + "…" + String(text.suffix(8)) : text
}

@MainActor
func diagnosticPolling(_ action: @MainActor () async -> Void) async {
    while !Task.isCancelled {
        await action()
        do { try await Task.sleep(nanoseconds: 3_000_000_000) }
        catch { return }
    }
}

struct DiagnosticIdentifiedValue: Identifiable {
    let id: String
    let value: DiagnosticValue
}

func diagnosticIdentified(_ values: [DiagnosticValue], keys: [String]) -> [DiagnosticIdentifiedValue] {
    values.enumerated().map { offset, value in
        let key = keys.first { !value[$0].text.isEmpty }
        return DiagnosticIdentifiedValue(id: key.map { "\($0):\(value[$0].text)" } ?? "pending:\(offset)", value: value)
    }
}
