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
    /// Groups moves that landed as part of one user-approved Curator plan. `nil` for
    /// the per-file live-classifier path. Used by `undoBatch` to reverse a whole plan
    /// in one click. Added in M8 — ledger lines without this field still decode.
    public let batchID: UUID?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sourceURL: URL,
        destinationURL: URL,
        decision: FolderDecision,
        undone: Bool = false,
        batchID: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.decision = decision
        self.undone = undone
        self.batchID = batchID
    }

    public func markingUndone() -> Move {
        Move(
            id: id,
            timestamp: timestamp,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            decision: decision,
            undone: true,
            batchID: batchID
        )
    }

    // MARK: - Codable (custom for backward-compat on `batchID`)

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, sourceURL, destinationURL, decision, undone, batchID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.sourceURL = try c.decode(URL.self, forKey: .sourceURL)
        self.destinationURL = try c.decode(URL.self, forKey: .destinationURL)
        self.decision = try c.decode(FolderDecision.self, forKey: .decision)
        self.undone = try c.decode(Bool.self, forKey: .undone)
        // Pre-M8 ledger lines don't have batchID — decodeIfPresent gives us `nil`.
        self.batchID = try c.decodeIfPresent(UUID.self, forKey: .batchID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(sourceURL, forKey: .sourceURL)
        try c.encode(destinationURL, forKey: .destinationURL)
        try c.encode(decision, forKey: .decision)
        try c.encode(undone, forKey: .undone)
        // Only emit batchID when set, so non-batch moves serialize identically to v1.
        try c.encodeIfPresent(batchID, forKey: .batchID)
    }
}
