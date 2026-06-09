import Foundation

/// Errors surfaced by Smith modules. Per CLAUDE.md §2.6 (fail safe), callers must
/// treat any thrown `SmithError` as "leave the file where it is and log it."
public enum SmithError: Error, Sendable, CustomStringConvertible {
    case watcherFailedToStart(reason: String)
    case fileNotFound(URL)
    case fileNotStable(URL)
    case sourceMissing(URL)
    case destinationNotDirectory(URL)
    case moveFailed(from: URL, to: URL, underlying: String)
    case undoFailed(reason: String)
    case ledgerCorrupt(reason: String)
    case classifierUnavailable(reason: String)
    case classificationFailed(reason: String)

    public var description: String {
        switch self {
        case .watcherFailedToStart(let reason):
            return "Watcher failed to start: \(reason)"
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .fileNotStable(let url):
            return "File is still being written: \(url.path)"
        case .sourceMissing(let url):
            return "Source missing: \(url.path)"
        case .destinationNotDirectory(let url):
            return "Destination is not a directory: \(url.path)"
        case .moveFailed(let from, let to, let underlying):
            return "Move failed (\(from.lastPathComponent) → \(to.path)): \(underlying)"
        case .undoFailed(let reason):
            return "Undo failed: \(reason)"
        case .ledgerCorrupt(let reason):
            return "Ledger is corrupt: \(reason)"
        case .classifierUnavailable(let reason):
            return "Classifier unavailable: \(reason)"
        case .classificationFailed(let reason):
            return "Classification failed: \(reason)"
        }
    }
}
