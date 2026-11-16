import Foundation

/// Capture policy for the next native startup, separate from display filtering.
enum DiagnosticCaptureLevel: String, CaseIterable, Identifiable {
    case error, warn, info, debug, trace

    var id: String { rawValue }
    var title: String { self == .warn ? "Warning" : rawValue.capitalized }

    /// Distribution builds select a default without depending on a receipt or
    /// a network request. An explicit user choice always takes precedence.
    static var buildDefault: Self {
        buildDefault(in: .main)
    }

    static func buildDefault(in bundle: Bundle) -> Self {
        guard let raw = bundle.object(
            forInfoDictionaryKey: "WavelengthDiagnosticCaptureDefault"
        ) as? String,
              let level = Self(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return .info
        }
        return level
    }

    static func saved(in defaults: UserDefaults,
                      buildDefault: Self = Self.buildDefault) -> Self {
        if let raw = defaults.string(forKey: "diagnosticsCaptureLevel"),
           let level = Self(rawValue: raw) {
            return level
        }
        if let legacy = defaults.object(forKey: "diagnosticsDebugCapture") as? Bool {
            return legacy ? .debug : .info
        }
        return buildDefault
    }
}
