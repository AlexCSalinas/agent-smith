import Foundation
import Models

/// Where Smith looks and where it files things. M3 will revisit "organized root" with the
/// user; for now both default to the project's Sandbox tree (Prime Directive 5 —
/// never touch real folders in dev).
public struct SmithConfig: Sendable {
    /// Folder Smith watches for new files. Default: ./Sandbox/Desktop relative to CWD.
    public var sourceFolder: URL
    /// Root under which classified files are filed. The classifier may pick from the
    /// direct subdirectories of this root, never elsewhere.
    public var organizedRoot: URL
    /// Where the append-only ledger is persisted.
    public var ledgerURL: URL
    /// Above this confidence, Smith auto-files. Below, the file goes to the review queue.
    /// Default 0.85 per CLAUDE.md §12 (subject to user calibration in M3).
    public var autoFileThreshold: Double

    public init(
        sourceFolder: URL,
        organizedRoot: URL,
        ledgerURL: URL,
        autoFileThreshold: Double = 0.85
    ) {
        self.sourceFolder = sourceFolder
        self.organizedRoot = organizedRoot
        self.ledgerURL = ledgerURL
        self.autoFileThreshold = autoFileThreshold
    }

    /// Default development config, anchored to the project's Sandbox tree at CWD.
    public static func sandboxDefault(projectRoot: URL? = nil) -> SmithConfig {
        let root = projectRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sandbox = root.appendingPathComponent("Sandbox", isDirectory: true)
        return SmithConfig(
            sourceFolder: sandbox.appendingPathComponent("Desktop", isDirectory: true),
            organizedRoot: sandbox.appendingPathComponent("Organized", isDirectory: true),
            ledgerURL: sandbox.appendingPathComponent("ledger.jsonl")
        )
    }

    /// List of candidate folder names — the direct subdirectories of `organizedRoot`.
    /// Smith never invents folders; the user creates them under the organized root manually.
    public func candidateFolders() -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: organizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()
    }
}
