import Foundation

/// One row in the append-only ledger. Captures everything needed to display the
/// activity feed AND to undo the move (Prime Directive 2 — every move reversible).
public struct Move: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    /// Where the file was when Smith assimilated it.
    public let sourceURL: URL
    /// Where the file lives now. After undo, this file no longer exists at this path.
    public let destinationURL: URL
    public let decision: FolderDecision
    /// True after a successful undo. Undone moves remain in the ledger; the log is append-only.
    public let undone: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sourceURL: URL,
        destinationURL: URL,
        decision: FolderDecision,
        undone: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.decision = decision
        self.undone = undone
    }

    public func markingUndone() -> Move {
        Move(
            id: id,
            timestamp: timestamp,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            decision: decision,
            undone: true
        )
    }
}
