import Foundation
import Models

/// Performs the actual file move. Two ironclad rules from CLAUDE.md §2:
///   1. Never delete a user file. We move, never `removeItem`.
///   2. Never overwrite. If a name collision exists at the destination, we rename
///      (`name.png` → `name (2).png` → `name (3).png` …) until the target is free.
public struct Filer: Sendable {
    public init() {}

    /// Move `source` into `destinationDirectory`, collision-renaming as needed.
    /// Returns the `Move` record (which the caller hands to the Ledger).
    public func move(
        _ source: URL,
        intoDirectory destinationDirectory: URL,
        decision: FolderDecision
    ) throws -> Move {
        let fm = FileManager.default

        guard fm.fileExists(atPath: source.path) else {
            throw SmithError.sourceMissing(source)
        }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: destinationDirectory.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw SmithError.destinationNotDirectory(destinationDirectory)
            }
        } else {
            // Auto-create the folder. This isn't "inventing a new taxonomy" (which the
            // classifier is forbidden from doing); the user must have picked it as a
            // candidate folder. We just materialize the directory if it's not there yet.
            try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        }

        let destination = Self.uniqueDestination(in: destinationDirectory, for: source.lastPathComponent)

        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            throw SmithError.moveFailed(from: source, to: destination, underlying: error.localizedDescription)
        }

        AppLog.filer.info(
            "moved \(source.lastPathComponent, privacy: .public) → \(destination.path, privacy: .public)"
        )

        return Move(
            sourceURL: source,
            destinationURL: destination,
            decision: decision
        )
    }

    /// Reverse a move: move the file back from `move.destinationURL` to `move.sourceURL`.
    /// If something now occupies the original source path, undo is refused — we never overwrite.
    public func undo(_ move: Move) throws -> Move {
        let fm = FileManager.default

        guard fm.fileExists(atPath: move.destinationURL.path) else {
            throw SmithError.undoFailed(reason: "file is no longer at destination: \(move.destinationURL.path)")
        }

        // If something exists at the original source path, refuse — never overwrite.
        // The user can address the conflict and try again.
        if fm.fileExists(atPath: move.sourceURL.path) {
            throw SmithError.undoFailed(reason: "a file already exists at the original source: \(move.sourceURL.path)")
        }

        // Ensure the source's parent directory exists (it might have been cleaned up).
        let parent = move.sourceURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            try fm.moveItem(at: move.destinationURL, to: move.sourceURL)
        } catch {
            throw SmithError.undoFailed(reason: error.localizedDescription)
        }

        AppLog.filer.info(
            "undo: \(move.destinationURL.path, privacy: .public) → \(move.sourceURL.path, privacy: .public)"
        )

        return move.markingUndone()
    }

    /// Computes a collision-free filename in `dir` based on `originalName`.
    /// `report.png` → `report.png` if free, else `report (2).png`, `report (3).png`, …
    /// Exposed `internal` for tests; production callers go through `move(_:)`.
    static func uniqueDestination(in dir: URL, for originalName: String) -> URL {
        let fm = FileManager.default
        let candidate = dir.appendingPathComponent(originalName)
        if !fm.fileExists(atPath: candidate.path) { return candidate }

        // Split stem + extension manually so multi-dot names like "foo.tar.gz" only chop the last segment.
        let nameURL = URL(fileURLWithPath: originalName)
        let ext = nameURL.pathExtension
        let stem = (originalName as NSString).deletingPathExtension

        for i in 2...9999 {
            let newName = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            let url = dir.appendingPathComponent(newName)
            if !fm.fileExists(atPath: url.path) { return url }
        }
        // 9998 collisions for one filename is absurd. Fall back to a UUID suffix to never overwrite.
        let uuid = UUID().uuidString.prefix(8)
        let newName = ext.isEmpty ? "\(stem) (\(uuid))" : "\(stem) (\(uuid)).\(ext)"
        return dir.appendingPathComponent(newName)
    }
}
