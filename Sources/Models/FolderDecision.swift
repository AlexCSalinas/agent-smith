import Foundation

/// The classifier's choice for where a file belongs.
///
/// The classifier never says "create a new folder" — `folder` MUST be one of
/// `FileSignals.candidateFolders`. Confidence below the auto-file threshold routes
/// the file to the review queue instead of moving it (Prime Directive 3).
public struct FolderDecision: Sendable, Equatable, Codable {
    public let folder: String
    public let confidence: Double
    public let reason: String

    public init(folder: String, confidence: Double, reason: String) {
        self.folder = folder
        self.confidence = min(max(confidence, 0.0), 1.0)
        self.reason = reason
    }
}
