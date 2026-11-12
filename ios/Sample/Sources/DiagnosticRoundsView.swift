import SwiftUI
import WalletKit

struct DiagnosticRoundsView: View {
    @EnvironmentObject private var store: WalletStore
    var pageToken = ""
    @State private var value: DiagnosticValue = .null
    @State private var error: String?

    var body: some View {
        WalletPage {
            if value == .null && error == nil { ProgressView() }
            ForEach(diagnosticIdentified(value["rounds"].items, keys: ["round_id", "round_key"])) { row in
                let round = row.value
                NavigationLink(destination: DiagnosticRoundDetailView(initial: round)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(round["state"].label(removing: "ROUND_STATE_")).font(.headline)
                        Text(diagnosticShort(round["round_id"].text.isEmpty ? round["round_key"].text : round["round_id"].text))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(WalletTheme.secondary)
                        if !round["waiting_reason"].text.isEmpty {
                            Text(round["waiting_reason"].text).font(.caption).foregroundStyle(WalletTheme.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                WalletDivider()
            }
            if value != .null && value["rounds"].items.isEmpty {
                Text("No rounds").foregroundStyle(WalletTheme.secondary)
            }
            if !value["next_page_token"].text.isEmpty {
                NavigationLink("Older rounds", destination: DiagnosticRoundsView(pageToken: value["next_page_token"].text))
            }
            DiagnosticFailure(message: error)
        }.navigationTitle("Rounds").navigationBarTitleDisplayMode(.inline)
            .task { await diagnosticPolling { await load() } }
    }

    private func load() async {
        do {
            let result = try await store.diagnosticRead(.rounds, pageToken: pageToken)
            try Task.checkCancellation()
            value = result; error = nil
        } catch { if !Task.isCancelled { self.error = error.walletMessage } }
    }
}

struct DiagnosticRoundDetailView: View {
    @EnvironmentObject private var store: WalletStore
    let initial: DiagnosticValue
    @State private var current: DiagnosticValue = .null
    @State private var error: String?
    private var round: DiagnosticValue { current == .null ? initial : current }

    var body: some View {
        WalletPage {
            Text(round["state"].label(removing: "ROUND_STATE_")).font(.title2.weight(.medium))
            if !round["waiting_reason"].text.isEmpty { Text(round["waiting_reason"].text).foregroundStyle(WalletTheme.secondary) }
            if !round["failure_reason"].text.isEmpty { DiagnosticFailure(message: round["failure_reason"].text) }
            if round["batch_window"] != .null {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Schedule").font(.headline)
                    DiagnosticRow(label: "Opens", value: diagnosticTime(round["batch_window"]["registration_opens_unix"].int))
                    DiagnosticRow(label: "Cutoff", value: diagnosticTime(round["batch_window"]["cutoff_unix"].int))
                    DiagnosticRow(label: "Planned join", value: diagnosticTime(round["batch_window"]["planned_join_unix_ms"].int, milliseconds: true))
                    Text("Local time. The planned join does not guarantee an iOS wake.")
                        .font(.caption).foregroundStyle(WalletTheme.secondary)
                }
            }
            DiagnosticRow(label: "Inputs", value: "\(round["input_outpoints"].items.count)")
            ForEach(round["input_outpoints"].items.map(\.text), id: \.self) { point in
                DiagnosticIdentifier(label: "Input", value: point)
            }
            if !round["round_id"].text.isEmpty { DiagnosticIdentifier(label: "Round ID", value: round["round_id"].text) }
            else { DiagnosticRow(label: "Round ID", value: "Not assigned") }
            if !round["round_key"].text.isEmpty { DiagnosticIdentifier(label: "Attempt", value: round["round_key"].text) }
            if !round["commitment_txid"].text.isEmpty {
                DiagnosticIdentifier(label: "Commitment transaction", value: round["commitment_txid"].text)
                if round["commitment_height"].int > 0 {
                    DiagnosticRow(label: "Recorded confirmation", value: round["commitment_height"].text)
                }
            }
            DiagnosticRaw(value: round)
            NavigationLink(destination: DiagnosticLogsView(initialQuery: round["round_id"].text.isEmpty ? round["round_key"].text : round["round_id"].text)) {
                Text("View related logs").frame(maxWidth: .infinity)
            }.buttonStyle(WalletButtonStyle(secondary: true))
            DiagnosticFailure(message: error)
        }.navigationTitle("Round").navigationBarTitleDisplayMode(.inline)
            .task { await diagnosticPolling { await load() } }
    }

    private func load() async {
        do {
            let result: DiagnosticValue
            if !initial["round_id"].text.isEmpty {
                result = try await store.diagnosticRead(.round, roundID: initial["round_id"].text)["round"]
            } else {
                let rounds = try await store.diagnosticRead(.rounds)["rounds"].items
                result = rounds.first { $0["round_key"].text == initial["round_key"].text } ?? .null
            }
            try Task.checkCancellation()
            current = result
            error = result == .null ? "This attempt is no longer in the active round list." : nil
        } catch { if !Task.isCancelled { self.error = error.walletMessage } }
    }
}

func diagnosticTime(_ value: Int64, milliseconds: Bool = false) -> String {
    guard value > 0 else { return "Not available" }
    let date = Date(timeIntervalSince1970: Double(value) / (milliseconds ? 1000 : 1))
    return milliseconds ? DiagnosticDates.precise.string(from: date) : date.formatted(date: .abbreviated, time: .standard)
}
