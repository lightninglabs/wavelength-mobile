import SwiftUI
import WalletKit

struct DiagnosticBackgroundView: View {
    @EnvironmentObject private var store: WalletStore
    @ObservedObject private var journal = DiagnosticJournal.shared

    var body: some View {
        WalletPage {
            let runs = journal.runs.filter { $0.network == store.network.rawValue }.reversed()
            if runs.isEmpty {
                Text("No background runs recorded yet").foregroundStyle(WalletTheme.secondary)
                Text("New pushes and scheduled opportunities will appear here when iOS runs the app.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            ForEach(Array(runs)) { run in
                NavigationLink(destination: DiagnosticRunView(runID: run.id)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(run.trigger).font(.headline)
                            Spacer()
                            Text(String(format: "%.1f s", run.duration)).font(.callout)
                        }
                        Text("\(diagnosticTime(run.started, milliseconds: true)) · \(run.status)")
                            .font(.caption).foregroundStyle(WalletTheme.secondary)
                    }
                }.buttonStyle(.plain)
                WalletDivider()
            }
        }.navigationTitle("Background").navigationBarTitleDisplayMode(.inline)
    }
}

private struct DiagnosticRunView: View {
    let runID: String
    @ObservedObject private var journal = DiagnosticJournal.shared
    private var run: DiagnosticRun? { journal.runs.first { $0.id == runID } }

    var body: some View {
        WalletPage {
            if let run {
                Text(String(format: "%.1f s", run.duration)).font(.largeTitle)
                Text(run.status).foregroundStyle(WalletTheme.secondary)
                DiagnosticRow(label: "Wake reason", value: run.trigger)
                DiagnosticRow(label: "Entry point", value: run.wake?.entryPoint ?? "Not recorded")
                DiagnosticRow(label: "Startup", value: run.startup ?? "Not recorded")
                if let source = run.wake?.source { DiagnosticRow(label: "Source", value: source) }
                DisclosureGroup("Timing details") {
                    if let host = run.hostBudgetSeconds { DiagnosticRow(label: "Host fallback", value: "\(host) s") }
                    if let native = run.nativeBudgetSeconds { DiagnosticRow(label: "SDK ceiling", value: "\(native) s") }
                    if let cleanup = run.observedDuration { DiagnosticRow(label: "Last observation", value: String(format: "%.2f s", cleanup)) }
                    Text("iOS can end the opportunity earlier. The host fallback includes startup; the SDK ceiling applies to native work.")
                        .font(.caption).foregroundStyle(WalletTheme.secondary)
                }
                if let batches = run.batches { DiagnosticRow(label: "Mailbox batches", value: "\(batches)") }
                if let checked = run.checked { DiagnosticRow(label: "VTXO owners checked", value: "\(checked)") }
                if let proofs = run.receiptProofs { DiagnosticRow(label: "Receipt proofs", value: "\(proofs)") }
                if let complete = run.completedReceipts { DiagnosticRow(label: "Complete proofs", value: "\(complete)") }
                if run.deferred == true { DiagnosticRow(label: "Maintenance", value: "Deferred") }
                if run.interrupted == true { DiagnosticRow(label: "Native result", value: "Interrupted") }
                if run.budgetExhausted == true { DiagnosticRow(label: "Native result", value: "SDK ceiling reached") }
                if run.more == true { DiagnosticRow(label: "Maintenance", value: "More work remains") }
                if run.needsForeground == true { DiagnosticRow(label: "Foreground", value: "Required") }
                Text("Mailbox batches count nonempty dispatch attempts. These counters do not prove a round completed.")
                    .font(.caption).foregroundStyle(WalletTheme.secondary)
                WalletDivider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(run.events.enumerated()), id: \.offset) { index, event in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(event.label).frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(String(format: "+%.2f s", (event.elapsedMilliseconds ?? Double(event.time - run.started)) / 1000))
                                if let duration = event.durationMilliseconds { Text(String(format: "took %.2f s", duration / 1000)) }
                            }
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(WalletTheme.secondary)
                        }
                        .padding(.leading, 28).padding(.bottom, index == run.events.count - 1 ? 0 : 24)
                        .overlay(alignment: .topLeading) {
                            GeometryReader { geometry in
                                if index < run.events.count - 1 {
                                    Path { path in
                                        path.move(to: CGPoint(x: 5, y: 10))
                                        path.addLine(to: CGPoint(x: 5, y: geometry.size.height + 10))
                                    }.stroke(WalletTheme.action.opacity(0.3), lineWidth: 1)
                                }
                                Circle().fill(WalletTheme.action).frame(width: 8, height: 8)
                                    .offset(x: 1, y: 6)
                            }.accessibilityHidden(true)
                        }
                    }
                }
                DiagnosticIdentifier(label: "Window ID", value: run.id)
                if let task = run.wake?.taskID { DiagnosticIdentifier(label: "Task", value: task) }
                DisclosureGroup("Trace JSON") {
                    CopyButton(value: run.pretty)
                    Text(run.pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                NavigationLink(destination: DiagnosticLogsView(since: run.started, until: run.logUntil)) {
                    Text("View logs during this run").frame(maxWidth: .infinity)
                }.buttonStyle(WalletButtonStyle(secondary: true))
            }
        }.navigationTitle("Background run").navigationBarTitleDisplayMode(.inline)
    }
}
