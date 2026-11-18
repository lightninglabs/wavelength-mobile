import SwiftUI
import WalletKit

struct DiagnosticBackgroundView: View {
    @EnvironmentObject private var store: WalletStore
    @ObservedObject private var journal = DiagnosticJournal.shared

    var body: some View {
        WalletPage {
            let runs = journal.runs.filter { $0.network == store.network.rawValue }
            let retained = Set(runs.map(\.id))
            let callbacksByOwner = Dictionary(grouping: runs.filter(\.endedWhileWaiting)) { $0.waitedBehind ?? "" }
            if runs.isEmpty {
                Text("No background runs recorded yet").foregroundStyle(WalletTheme.secondary)
                Text("New pushes and scheduled opportunities will appear here when iOS runs the app.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            ForEach(Array(runs.reversed())) { run in
                if !run.endedWhileWaiting || !retained.contains(run.waitedBehind ?? "") {
                    DiagnosticRunLink(run: run, relatedCount: callbacksByOwner[run.id]?.count ?? 0)
                    WalletDivider()
                }
            }
        }.navigationTitle("Background").navigationBarTitleDisplayMode(.inline)
    }
}

private struct DiagnosticRunLink: View {
    let run: DiagnosticRun
    var relatedCount = 0

    var body: some View {
        NavigationLink(destination: DiagnosticRunView(runID: run.id)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(run.wakeTitle).font(.headline)
                    Spacer()
                    Text(String(format: "%.1f s", run.duration)).font(.callout)
                }
                Text("\(diagnosticTime(run.started, milliseconds: true)) · \(run.outcomeLabel)")
                    .font(.caption).foregroundStyle(WalletTheme.secondary)
                if run.wakeReasonUnavailable {
                    Text("Reason unavailable").font(.caption).foregroundStyle(WalletTheme.secondary)
                }
                if relatedCount > 0 {
                    Text("\(relatedCount + 1) callbacks").font(.caption).foregroundStyle(WalletTheme.secondary)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct DiagnosticRunView: View {
    let runID: String
    @ObservedObject private var journal = DiagnosticJournal.shared
    private var run: DiagnosticRun? { journal.runs.first { $0.id == runID } }

    var body: some View {
        WalletPage {
            if let run {
                Text(run.wakeTitle).font(.largeTitle)
                Text("\(run.outcomeLabel) · \(String(format: "%.1f s", run.duration))")
                    .foregroundStyle(WalletTheme.secondary)
                if run.wakeReasonUnavailable { DiagnosticRow(label: "Producer reason", value: "Unavailable") }
                DiagnosticRow(label: "Received", value: diagnosticTime(run.started, milliseconds: true))
                DiagnosticRow(label: "Entry point", value: run.wake?.entryPoint ?? "Not recorded")
                DiagnosticRow(label: "Startup", value: run.startup ?? "Not recorded")
                if let source = run.wake?.source { DiagnosticRow(label: "Source", value: source) }
                if let producer = run.wake?.producer, let label = producer.reason?.deadlineLabel,
                   let deadline = producer.deadline {
                    DiagnosticRow(label: label, value: diagnosticTime(deadline, milliseconds: false))
                }
                DisclosureGroup("Timing details") {
                    if let host = run.hostBudgetSeconds { DiagnosticRow(label: "Host fallback", value: "\(host) s") }
                    if let native = run.nativeBudgetSeconds { DiagnosticRow(label: "SDK ceiling", value: "\(native) s") }
                    if let cleanup = run.observedDuration { DiagnosticRow(label: "Last observation", value: String(format: "%.2f s", cleanup)) }
                    Text("iOS can end the opportunity earlier. The host fallback includes startup; the SDK ceiling applies to native work.")
                        .font(.caption).foregroundStyle(WalletTheme.secondary)
                }
                Text("Work observed").font(.headline)
                if let batches = run.batches { DiagnosticRow(label: "Mailbox batches attempted", value: "\(batches)") }
                else {
                    Text(run.nativeBudgetSeconds == nil ? "No native work recorded" : "Work result unavailable")
                        .font(.caption).foregroundStyle(WalletTheme.secondary)
                }
                if let checked = run.checked { DiagnosticRow(label: "VTXO owners checked", value: "\(checked)") }
                if let proofs = run.receiptProofs { DiagnosticRow(label: "Receipt proofs", value: "\(proofs)") }
                if let complete = run.completedReceipts { DiagnosticRow(label: "Complete proofs", value: "\(complete)") }
                if run.deferred == true { DiagnosticRow(label: "Maintenance", value: "Deferred") }
                if run.interrupted == true { DiagnosticRow(label: "Native result", value: "Interrupted") }
                if run.budgetExhausted == true { DiagnosticRow(label: "Native result", value: "SDK ceiling reached") }
                if run.more == true { DiagnosticRow(label: "Maintenance", value: "More work remains") }
                if run.needsForeground == true { DiagnosticRow(label: "Foreground", value: "Required") }
                let waiters = journal.runs.filter {
                    $0.network == run.network && $0.waitedBehind == run.id && $0.endedWhileWaiting
                }
                if !waiters.isEmpty {
                    WalletDivider()
                    Text("Callbacks that waited").font(.headline)
                    ForEach(waiters) { DiagnosticRunLink(run: $0) }
                }
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
            } else {
                Text("This run is no longer retained.").foregroundStyle(WalletTheme.secondary)
            }
        }.navigationTitle("Background run").navigationBarTitleDisplayMode(.inline)
    }
}
