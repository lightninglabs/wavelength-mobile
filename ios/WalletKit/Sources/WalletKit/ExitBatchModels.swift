import Foundation

/// Admission results for one native cooperative-exit request. They do not
/// describe payout confirmation. A missing input result stays unknown.
public struct ExitBatchResult: Decodable, Sendable {
    public let results: [ExitBatchInputResult]?
    public let destination: String
    /// One aggregate activity row for the accepted subset only.
    public let activityID: String?
    enum CodingKeys: String, CodingKey {
        case results = "Results", destination = "Destination", activityID = "ActivityID"
    }
}

public struct ExitBatchInputResult: Decodable, Sendable {
    public let outpoint: String
    /// Native values are accepted, failed and unknown. Future values must also
    /// be treated as unknown by the host, rather than as successful admission.
    public let outcome: String
    public let error: String
    enum CodingKeys: String, CodingKey {
        case outpoint = "Outpoint", outcome = "Outcome", error = "Error"
    }
}
