import SwiftUI
import WalletKit

struct DiagnosticLogsView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("diagnosticsDebugCapture") private var debugCapture = false
    @FocusState private var filterFocused: Bool
    var since: Int64? = nil
    var until: Int64? = nil
    @State private var query: String
    @State private var level = "All levels"
    @State private var source = "All sources"
    @State private var paused = false
    @State private var logWindow = DiagnosticLogWindow()
    private var follow: Bool { logWindow.following }
    @State private var visibleLimit = 500
    @State private var records: [DiagnosticLogRecord] = []
    @State private var error: String?
    @State private var historyUnavailable = false
    @State private var share: DiagnosticShare?

    init(initialQuery: String = "", since: Int64? = nil, until: Int64? = nil) {
        _query = State(initialValue: initialQuery); self.since = since; self.until = until
    }
    private var matches: [DiagnosticLogRecord] { filtered(records) }
    private func filtered(_ records: [DiagnosticLogRecord]) -> [DiagnosticLogRecord] {
        records.filter { record in
            record.matches(query) && (level == "All levels" || record.level == level) &&
            (source == "All sources" || record.source == source) &&
            (since.map { start in record.time >= start } ?? true) && (until.map { end in record.time <= end } ?? true)
        }
    }
    private var shown: [DiagnosticLogRecord] {
        Array(filtered(logWindow.records(live: records)).suffix(visibleLimit))
    }

    var body: some View {
        VStack(spacing: 16) {
            TextField("Filter logs", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($filterFocused).submitLabel(.done).onSubmit { filterFocused = false }
                .padding(12).background(WalletTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("diagnostics.logFilter")
            HStack {
                Picker("Level", selection: $level) {
                    ForEach(["All levels", "TRACE", "DEBUG", "INFO", "WARN", "ERROR"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                Spacer()
                Picker("Source", selection: $source) {
                    Text("All sources").tag("All sources")
                    ForEach(Array(Set(records.map(\.source))).sorted(), id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
            }.font(.caption).tint(WalletTheme.foreground)
            HStack {
                Circle().fill(paused ? WalletTheme.secondary : WalletTheme.action).frame(width: 6, height: 6)
                Text(paused ? "Paused" : follow ? "Live" : "Browsing")
                Spacer()
                Text("\(matches.count) matches").foregroundStyle(WalletTheme.secondary)
                    .accessibilityIdentifier("diagnostics.logCount")
                    .accessibilityValue(records.last.map {
                        "Latest at \(diagnosticLogTime($0.time))"
                    } ?? "")
            }.font(.caption)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if matches.count > visibleLimit {
                            Button("Show older logs") { visibleLimit += 500 }.font(.caption)
                        }
                        ForEach(shown) { record in
                            NavigationLink(destination: DiagnosticLogDetailView(record: record)) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("\(diagnosticLogTime(record.time))  \(record.level)  \(record.source)")
                                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(WalletTheme.secondary)
                                    Text(diagnosticHighlight(record.message, query: query))
                                        .font(.system(.caption, design: .monospaced)).lineLimit(4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.buttonStyle(.plain).id(record.id)
                                .accessibilityIdentifier("diagnostics.log.\(record.id)")
                            WalletDivider()
                        }
                        if records.isEmpty { Text("No captured logs yet").foregroundStyle(WalletTheme.secondary) }
                        else if matches.isEmpty { Text("No matches").foregroundStyle(WalletTheme.secondary) }
                    }
                }.accessibilityIdentifier("diagnostics.logScroll")
                    .simultaneousGesture(DragGesture().onChanged { _ in
                        if follow {
                            // Hold the displayed snapshot while the bounded
                            // native buffer rotates. Capture and its count stay
                            // live; eviction cannot shift the row being read.
                            logWindow.browse(records)
                        }
                    })
                    .onChange(of: shown.last?.id) { id in
                        // Polling and pause/resume never re-enable follow after
                        // a user scroll. Only the explicit button below does.
                        if follow, let id {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                Button {
                    logWindow.followLatest()
                    if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
                } label: { Label("Follow latest", systemImage: "arrow.down") }
                    .font(.caption).buttonStyle(WalletButtonStyle(secondary: true))
                    .accessibilityIdentifier("diagnostics.follow")
                    .accessibilityValue(follow ? "Following" : "Browsing")
            }
            if historyUnavailable { Text("Persistent native history is unavailable. Showing captured records.").font(.caption).foregroundStyle(WalletTheme.secondary) }
            DiagnosticFailure(message: error)
        }.padding(.horizontal, 24).padding(.bottom, 16)
            .background(WalletTheme.background.ignoresSafeArea())
            .navigationTitle("Logs").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { paused.toggle(); filterFocused = false } label: { Image(systemName: paused ? "play" : "pause") }
                        .accessibilityLabel(paused ? "Resume logs" : "Pause logs")
                    Button { share = .init(text: diagnosticLogExport(matches)) } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share filtered logs")
                    Menu {
                        Button("Add marker") {
                            DiagnosticJournal.shared.record(network: store.network.rawValue, label: "User marker")
                        }
                        Picker("Capture detail", selection: $debugCapture) {
                            Text("Info").tag(false)
                            Text("Debug").tag(true)
                        }
                        Text("Applies on the next wallet startup.")
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Log options")
                }
            }
            .sheet(item: $share) { DiagnosticShareSheet(text: $0.text) }
            .task { await poll() }
    }

    private func poll() async {
        while !Task.isCancelled {
            if !paused {
                do {
                    let result = try await store.diagnosticLogs()
                    try Task.checkCancellation()
                    let host = DiagnosticJournal.shared.entries.filter { $0.source == "App/\(store.network.rawValue)" }
                    records = (result.entries + host).sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
                    historyUnavailable = result.historyUnavailable; error = nil
                } catch { if !Task.isCancelled { self.error = error.walletMessage } }
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return }
        }
    }
}

private struct DiagnosticLogDetailView: View {
    let record: DiagnosticLogRecord
    @State private var share: DiagnosticShare?
    var body: some View {
        WalletPage {
            DiagnosticRow(label: "Time", value: diagnosticTime(record.time, milliseconds: true))
            DiagnosticRow(label: "Level", value: record.level)
            DiagnosticRow(label: "Source", value: record.source)
            Text(record.message).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            CopyButton(value: record.message)
            Button("Share") { share = .init(text: diagnosticLogExport([record])) }.buttonStyle(WalletButtonStyle(secondary: true))
        }.navigationTitle("Log entry").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $share) { DiagnosticShareSheet(text: $0.text) }
    }
}

func diagnosticHighlight(_ message: String, query: String) -> AttributedString {
    var result = AttributedString(message)
    guard !query.isEmpty else { return result }
    var cursor = message.startIndex
    while cursor < message.endIndex,
          let found = message.range(of: query, options: .caseInsensitive, range: cursor..<message.endIndex) {
        if let start = AttributedString.Index(found.lowerBound, within: result),
           let end = AttributedString.Index(found.upperBound, within: result) {
            result[start..<end].backgroundColor = WalletTheme.action.opacity(0.22)
        }
        cursor = found.upperBound
    }
    return result
}

func diagnosticLogTime(_ milliseconds: Int64) -> String {
    DiagnosticDates.clock.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
}

func diagnosticLogExport(_ records: [DiagnosticLogRecord]) -> String {
    records.map { "\(DiagnosticDates.utc.string(from: Date(timeIntervalSince1970: Double($0.time) / 1000))) \($0.level) \($0.source) \($0.message)" }.joined(separator: "\n")
}

enum DiagnosticDates {
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    static let precise: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return formatter
    }()
    static let utc: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Holds a bounded captured snapshot so native eviction cannot move rows while
/// browsing. Following switches back to the current native/host buffer.
struct DiagnosticLogWindow {
    private var held: [DiagnosticLogRecord]?
    var following: Bool { held == nil }
    mutating func browse(_ records: [DiagnosticLogRecord]) {
        if held == nil { held = records }
    }
    mutating func followLatest() { held = nil }
    func records(live: [DiagnosticLogRecord]) -> [DiagnosticLogRecord] { held ?? live }
}
