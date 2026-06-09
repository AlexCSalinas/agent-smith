import Foundation
import Models

/// A file the classifier wasn't confident about. Lives in the review queue until the user
/// approves (which routes through Filer + Ledger) or dismisses.
public struct ReviewItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let url: URL
    public let signals: FileSignals
    public let suggestion: FolderDecision

    public init(id: UUID = UUID(), url: URL, signals: FileSignals, suggestion: FolderDecision) {
        self.id = id
        self.url = url
        self.signals = signals
        self.suggestion = suggestion
    }
}
