import SwiftUI
import WalletKit

struct DiagnosticLogSnapshot: Identifiable, Sendable {
    let id = UUID()
    let records: [DiagnosticLogRecord]
    let network: String
    let interval: Bool
}

struct DiagnosticLogShareView: View {
    let snapshot: DiagnosticLogSnapshot
    @State private var text: String?
    @State private var files: DiagnosticLogFiles?
    @State private var selection: Format?
    @State private var error: String?
    private enum Format { case zip, file, text }

    var body: some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents(selection == nil ? [.height(400), .large] : [.large])
                .presentationDragIndicator(.visible)
        } else { content }
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            if let selection, let text {
                if selection == .text { DiagnosticShareSheet(text: text) }
                else if let files { DiagnosticShareSheet(file: selection == .zip ? files.zip : files.text) }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Share logs").font(.title3.weight(.semibold)).padding(.bottom, 24)
                    if let files {
                        row("Share ZIP", subtitle: "Compressed file · \(size(files.zipSize))", icon: "doc.zipper", format: .zip)
                        WalletDivider()
                        row("Share text file", subtitle: "Plain log file · \(size(files.textSize))", icon: "doc", format: .file)
                        WalletDivider()
                        row("Share as text", subtitle: "Paste into a message", icon: "text.bubble", format: .text)
                    } else if let error {
                        Text(error).font(.footnote).foregroundStyle(WalletTheme.secondary)
                        if text != nil {
                            row("Share as text", subtitle: "Paste into a message", icon: "text.bubble", format: .text)
                        }
                    } else {
                        HStack(spacing: 12) { ProgressView(); Text("Preparing logs…") }
                            .foregroundStyle(WalletTheme.secondary)
                    }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 12).background(WalletTheme.background.ignoresSafeArea())
            }
        }
        .task {
            do {
                let value = await Task.detached(priority: .userInitiated) { diagnosticLogExport(snapshot.records) }.value
                try Task.checkCancellation()
                text = value
                if snapshot.interval { selection = .text }
                else {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try DiagnosticLogFiles.prepare(text: value, network: snapshot.network)
                    }.value
                    try Task.checkCancellation()
                    files = result
                }
            } catch is CancellationError {} catch { self.error = "Couldn’t prepare logs. \(error.localizedDescription)" }
        }
    }

    private func size(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    private func row(_ title: String, subtitle: String, icon: String, format: Format) -> some View {
        Button { selection = format } label: {
            HStack(spacing: 18) {
                Image(systemName: icon).font(.title2).frame(width: 28)
                    .foregroundStyle(format == .zip ? WalletTheme.action : WalletTheme.foreground)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(WalletTheme.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(WalletTheme.secondary)
            }.padding(.vertical, 18).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("diagnostics.share.\(format)")
    }
}
