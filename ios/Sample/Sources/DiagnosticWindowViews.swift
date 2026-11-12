import SwiftUI
import WalletKit

/// Block-height boundaries supplied by the daemon, not a wall-clock estimate.
struct DiagnosticExpiryWindow: Equatable {
    let current: Int64
    let expiry: Int64
    let refreshStart: Int64
    let criticalStart: Int64
    init?(_ value: DiagnosticValue) {
        current = value["current_height"].int
        expiry = value["batch_expiry"].int
        let refresh = value["refresh_threshold_blocks"].int
        let critical = value["critical_threshold_blocks"].int
        guard current > 0, expiry > 0, refresh > 0, critical > 0 else { return nil }
        refreshStart = expiry - refresh
        criticalStart = expiry - critical
    }
}

struct DiagnosticWindowBand: View {
    let lower: Double
    let upper: Double
    let current: Double
    let opens: Double
    let closes: Double
    var critical: Double? = nil
    var planned: Double? = nil

    private func position(_ value: Double) -> Double {
        min(1, max(0, (value - lower) / max(1, upper - lower)))
    }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(WalletTheme.line).frame(height: 8)
                Capsule().fill(WalletTheme.action.opacity(0.45))
                    .frame(width: max(0, width * (position(closes) - position(opens))), height: 8)
                    .offset(x: width * position(opens))
                if let critical {
                    Capsule().fill(Color.orange.opacity(0.75))
                        .frame(width: max(0, width * (position(closes) - position(critical))), height: 8)
                        .offset(x: width * position(critical))
                }
                if let planned {
                    Rectangle().fill(WalletTheme.foreground.opacity(0.5)).frame(width: 2, height: 25)
                        .offset(x: min(width - 2, width * position(planned)))
                }
                VStack(spacing: 0) {
                    Circle().fill(WalletTheme.foreground).frame(width: 7, height: 7)
                    Rectangle().fill(WalletTheme.foreground).frame(width: 1, height: 18)
                }.offset(x: min(width - 7, max(0, width * position(current) - 3.5)), y: -8)
            }.frame(height: 40)
        }.frame(height: 40).accessibilityHidden(true)
    }
}

struct DiagnosticExpiryTimeline: View {
    let expiryInfo: DiagnosticValue
    var body: some View {
        if let window = DiagnosticExpiryWindow(expiryInfo) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Now \(window.current.formatted())").font(.system(.caption, design: .monospaced))
                    .foregroundStyle(WalletTheme.secondary)
                DiagnosticWindowBand(lower: Double(min(window.current, window.refreshStart)),
                    upper: Double(max(window.expiry, window.current) + 1), current: Double(window.current),
                    opens: Double(window.refreshStart), closes: Double(window.expiry), critical: Double(window.criticalStart))
                HStack {
                    Text("Refresh")
                    Spacer()
                    Text("Critical").foregroundStyle(.orange)
                    Spacer()
                    Text("Expiry")
                }.font(.caption).foregroundStyle(WalletTheme.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Current height \(window.current), refresh from \(window.refreshStart), critical from \(window.criticalStart), expiry \(window.expiry)")
        } else {
            Text("Refresh timing unknown").font(.footnote).foregroundStyle(WalletTheme.secondary)
        }
    }
}

struct DiagnosticRoundWindow: View {
    let window: DiagnosticValue
    var body: some View {
        let opens = Double(window["registration_opens_unix"].int)
        let cutoff = Double(window["cutoff_unix"].int)
        if opens > 0 && cutoff > opens {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let now = timeline.date.timeIntervalSince1970
                let planned = Double(window["planned_join_unix_ms"].int) / 1000
                VStack(alignment: .leading, spacing: 8) {
                    Text(now < opens ? "Not open yet" : now < cutoff ? "Registration open" : "Registration closed")
                        .font(.caption).foregroundStyle(WalletTheme.secondary)
                    DiagnosticWindowBand(lower: min(now, opens - (cutoff - opens) * 0.2),
                        upper: max(now, cutoff), current: now, opens: opens, closes: cutoff,
                        planned: planned > 0 ? planned : nil)
                    HStack {
                        Text("Opens")
                        Spacer()
                        if planned > 0 { Text("Planned join") }
                        Spacer()
                        Text("Cutoff")
                    }.font(.caption).foregroundStyle(WalletTheme.secondary)
                }
            }
        }
    }
}

struct DiagnosticRefreshTimingView: View {
    @EnvironmentObject private var store: WalletStore
    let outpoint: String
    @State private var expiry: DiagnosticValue = .null
    @State private var terms: DiagnosticValue = .null
    @State private var error: String?

    var body: some View {
        WalletPage {
            Text(diagnosticExpiry(expiry)).font(.title2.weight(.medium))
            DiagnosticExpiryTimeline(expiryInfo: expiry)
            if let window = DiagnosticExpiryWindow(expiry) {
                DiagnosticRow(label: "Refresh from", value: window.refreshStart.formatted())
                DiagnosticRow(label: "Critical from", value: window.criticalStart.formatted())
                DiagnosticRow(label: "Expiry height", value: window.expiry.formatted())
                if terms != .null {
                    let free = terms["free_refresh_window_blocks"].int
                    DiagnosticRow(label: "Operator free window", value: free == 0 ? "Disabled" : "\(free.formatted()) blocks")
                    if free > 0 {
                        DiagnosticRow(label: "Free window opens", value: (window.expiry - free).formatted())
                    }
                }
                Text("Thresholds use the daemon’s expiry policy. Automatic refresh also requires an eligible zero-fee round and an iOS execution opportunity. Operator terms are the session snapshot.")
                    .font(.footnote).foregroundStyle(WalletTheme.secondary)
            }
            DiagnosticFailure(message: error)
        }.navigationTitle("Refresh timing").navigationBarTitleDisplayMode(.inline)
            .task { await diagnosticPolling { await load() } }
    }
    private func load() async {
        do {
            let value = try await store.diagnosticRead(.vtxo, outpoint: outpoint)
            let info = try await store.diagnosticRead(.info)
            try Task.checkCancellation()
            expiry = value["expiry_info"]; terms = info["server_info"]; error = nil
        } catch { if !Task.isCancelled { self.error = error.walletMessage } }
    }
}
