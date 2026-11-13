import Foundation

/// Capture policy for the next native startup, separate from display filtering.
enum DiagnosticCaptureLevel: String, CaseIterable, Identifiable {
    case error, warn, info, debug, trace

    var id: String { rawValue }
    var title: String { self == .warn ? "Warning" : rawValue.capitalized }

    static func saved(in defaults: UserDefaults) -> Self {
        if let raw = defaults.string(forKey: "diagnosticsCaptureLevel"),
           let level = Self(rawValue: raw) {
            return level
        }
        return defaults.bool(forKey: "diagnosticsDebugCapture") ? .debug : .info
    }
}
