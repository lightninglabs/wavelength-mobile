import CoreFoundation
import Foundation

/// Host observations, not an explanation of the OS scheduler's private decision.
struct DiagnosticWakeContext: Codable, Equatable {
    let entryPoint: String
    var taskID: String? = nil
    var source: String? = nil
    var attempt: Int? = nil
    var producer: DiagnosticProducerWake? = nil
}

/// Optional relay metadata used only for diagnostics on a known local route.
struct DiagnosticProducerWake: Codable, Equatable {
    enum Reason: String {
        case scheduledRound = "scheduled_round"
        case roundSigning = "round_signing"
        case mailboxUpdate = "mailbox_update"

        var title: String {
            switch self {
            case .scheduledRound: return "Scheduled round"
            case .roundSigning: return "Round signing"
            case .mailboxUpdate: return "Mailbox update"
            }
        }

        var deadlineLabel: String? {
            switch self {
            case .scheduledRound: return "Registration closes"
            case .roundSigning: return "Round wake deadline"
            case .mailboxUpdate: return nil
            }
        }
    }

    let reasonCode: String
    let deadline: Int64?
    var reason: Reason? { Reason(rawValue: reasonCode) }

    init?(payload: [String: Any]) {
        guard let code = payload["wake_reason"] as? String, let reason = Reason(rawValue: code) else { return nil }
        reasonCode = reason.rawValue
        if reason.deadlineLabel != nil, let number = payload["wake_deadline_unix"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           (1...253_402_300_799).contains(number.doubleValue),
           Double(number.int64Value) == number.doubleValue {
            deadline = number.int64Value
        } else {
            deadline = nil
        }
    }
}

extension DiagnosticRun {
    var wakeTitle: String { wake?.producer?.reason?.title ?? trigger }
    var wakeReasonUnavailable: Bool { trigger == "Relay wake" && wake?.producer?.reason == nil }

    var endedWhileWaiting: Bool {
        expiredWhileWaiting == true && nativeBudgetSeconds == nil
    }

    var outcomeLabel: String {
        if endedWhileWaiting { return "Expired while waiting" }
        if status == "No native window", events.contains(where: { $0.label == "No eligible local wake route" }) {
            return "Rejected · No eligible local route"
        }
        return status
    }

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
