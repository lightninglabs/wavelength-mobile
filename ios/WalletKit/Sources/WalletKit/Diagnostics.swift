import Foundation

/// A lossless JSON value for read-only native RPC inspection. Integer strings
/// emitted by protobuf JSON remain strings when copied or shared.
public enum DiagnosticValue: Codable, Sendable, Equatable {
    case object([String: DiagnosticValue])
    case array([DiagnosticValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([DiagnosticValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: DiagnosticValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public subscript(_ key: String) -> DiagnosticValue {
        if case .object(let object) = self { return object[key] ?? .null }
        return .null
    }
    public var text: String {
        switch self {
        case .string(let v): return v
        case .integer(let v): return String(v)
        case .number(let v): return String(v)
        case .bool(let v): return v ? "true" : "false"
        default: return ""
        }
    }
    public var int: Int64 { Int64(text) ?? 0 }
    public var flag: Bool { if case .bool(let v) = self { return v }; return false }
    public var items: [DiagnosticValue] { if case .array(let v) = self { return v }; return [] }
    public var fields: [String: DiagnosticValue] { if case .object(let v) = self { return v }; return [:] }
    public var pretty: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? ""
    }
    public func label(removing prefix: String) -> String {
        text.replacingOccurrences(of: prefix, with: "")
            .lowercased().replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Only these finite read operations can cross the diagnostics bridge.
public enum DiagnosticView: String, Sendable {
    case vtxos, vtxo, anchors, rounds, round, info, balance, oor, swaps, credits
}

public struct DiagnosticLogRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let time: Int64
    public let level: String
    public let source: String
    public let message: String

    public init(id: String, time: Int64, level: String, source: String, message: String) {
        self.id = id; self.time = time; self.level = level
        self.source = source; self.message = message
    }
    public func matches(_ query: String) -> Bool {
        query.isEmpty || "\(source) \(level) \(message)".range(of: query, options: .caseInsensitive) != nil
    }
    enum CodingKeys: String, CodingKey {
        case id = "ID", time = "Time", level = "Level"
        case source = "Source", message = "Message"
    }
}

public struct DiagnosticLogs: Decodable, Sendable {
    public let entries: [DiagnosticLogRecord]
    public let historyUnavailable: Bool
    enum CodingKeys: String, CodingKey {
        case entries = "Entries", historyUnavailable = "HistoryUnavailable"
    }
}
