import Foundation

/// Host observations, not an explanation of the OS scheduler's private decision.
struct DiagnosticWakeContext: Codable, Equatable {
    let entryPoint: String
    var taskID: String? = nil
    var source: String? = nil
    var attempt: Int? = nil
}

extension DiagnosticRun {
    var logUntil: Int64? {
        finished.map { max($0, events.last?.time ?? $0) }
    }
    var observedDuration: Double? {
        guard let elapsedAtFinish, let last = events.last?.elapsedMilliseconds,
              last > elapsedAtFinish + 1 else { return nil }
        return last / 1000
    }
    var pretty: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
