import Foundation
import Models

/// Append-only JSON-Lines log of every `Move`. Powers the activity feed and the undo flow.
///
/// On disk this is one JSON object per line. Undo doesn't rewrite history — it appends an
/// updated `Move` record (with `undone = true`). On load we fold by id, keeping the most
/// recent record per id, so the in-memory state reflects current truth without ever
/// mutating earlier lines.
public actor Ledger {
    public let url: URL
    private var movesByID: [UUID: Move] = [:]
    private var order: [UUID] = []

    public init(at url: URL) throws {
        self.url = url
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path) {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw SmithError.ledgerCorrupt(reason: "could not read ledger file: \(error.localizedDescription)")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // Each non-empty line is a JSON Move.
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                guard let move = try? decoder.decode(Move.self, from: Data(line)) else {
                    // Tolerate one bad line rather than refusing to start — log it and continue.
                    // Mass corruption would manifest as zero records, which the UI shows as "empty."
                    AppLog.ledger.error("skipping unparseable ledger line")
                    continue
                }
                if movesByID[move.id] == nil {
                    order.append(move.id)
                }
                movesByID[move.id] = move
            }
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
    }

    /// Append a new move (or an updated record for an existing move — e.g. an undo).
    public func append(_ move: Move) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(move)
        var line = Data()
        line.append(json)
        line.append(0x0A) // newline

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw SmithError.ledgerCorrupt(reason: "could not open ledger for write: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            throw SmithError.ledgerCorrupt(reason: "ledger write failed: \(error.localizedDescription)")
        }

        if movesByID[move.id] == nil {
            order.append(move.id)
        }
        movesByID[move.id] = move
        AppLog.ledger.info("appended move \(move.id.uuidString, privacy: .public)")
    }

    /// Record that a move was undone by appending the move's `undone` variant.
    public func recordUndo(of moveID: UUID) throws -> Move {
        guard let existing = movesByID[moveID] else {
            throw SmithError.undoFailed(reason: "move \(moveID.uuidString) not in ledger")
        }
        let undone = existing.markingUndone()
        try append(undone)
        return undone
    }

    /// All moves in insertion order (each id appears once, reflecting its latest state).
    public func all() -> [Move] {
        order.compactMap { movesByID[$0] }
    }

    /// Most recent first, capped to `limit`.
    public func recent(limit: Int = 20) -> [Move] {
        Array(all().reversed().prefix(limit))
    }

    /// Look up a move by id (latest state).
    public func get(_ id: UUID) -> Move? { movesByID[id] }
}
