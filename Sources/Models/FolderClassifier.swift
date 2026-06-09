import Foundation

/// The classifier seam (CLAUDE.md §5). `LocalClassifier` is the default; a future
/// `RemoteClassifier` would slot in here without touching anything else.
public protocol FolderClassifier: Sendable {
    /// Returns a `FolderDecision` whose `folder` is one of `signals.candidateFolders`.
    /// Throwing here means "leave the file alone" — Triage will route it to review.
    func classify(_ signals: FileSignals) async throws -> FolderDecision
}
