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
    /// Above this confidence, Smith auto-files into the picked folder.
    /// Below, behavior depends on `fallbackFolder`.
    public var autoFileThreshold: Double
    /// When the classifier returns below-threshold confidence: if this is set AND exists
    /// under `organizedRoot`, the file is auto-filed there. If nil, the file goes to the
    /// review queue (the original Prime Directive 3 behavior).
    ///
    /// Setting this to "Other" disables the review queue entirely — Smith always moves.
    public var fallbackFolder: String?

    public init(
        sourceFolder: URL,
        organizedRoot: URL,
        ledgerURL: URL,
        autoFileThreshold: Double = 0.85,
        fallbackFolder: String? = nil
    ) {
        self.sourceFolder = sourceFolder
        self.organizedRoot = organizedRoot
        self.ledgerURL = ledgerURL
        self.autoFileThreshold = autoFileThreshold
        self.fallbackFolder = fallbackFolder
    }

    /// Default development config, anchored to the project's Sandbox tree at CWD.
    /// Used by tests and by the demo-against-sandbox flow before M5.
    public static func sandboxDefault(projectRoot: URL? = nil) -> SmithConfig {
        let root = projectRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sandbox = root.appendingPathComponent("Sandbox", isDirectory: true)
        return SmithConfig(
            sourceFolder: sandbox.appendingPathComponent("Desktop", isDirectory: true),
            organizedRoot: sandbox.appendingPathComponent("Organized", isDirectory: true),
            ledgerURL: sandbox.appendingPathComponent("ledger.jsonl")
        )
    }

    /// Watch the real ~/Desktop; file into ~/Pictures/Screenshots/<folder>. Source and
    /// organized root deliberately live in different trees so cleared files don't accumulate
    /// sub-folders on the Desktop. Ledger lives in Application Support like any normal mac app.
    ///
    /// This is the Prime Directive 5 deviation (CLAUDE.md §2.5): Smith now touches a real
    /// user folder. On first read, macOS will TCC-prompt the parent process (Terminal, or
    /// the .app bundle in M5). Until that's granted, the watcher will refuse to start.
    public static func userDesktopDefault() -> SmithConfig {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let appSupport = home.appendingPathComponent("Library/Application Support/AgentSmith", isDirectory: true)
        // Source and organizedRoot are both Desktop: the category folders live on Desktop
        // (visible/clickable) and files dropped onto Desktop get sorted INTO those subfolders.
        // The watcher is filtered to top-level events so it never recurses into the
        // categories and re-sorts what it just filed.
        return SmithConfig(
            sourceFolder: desktop,
            organizedRoot: desktop,
            ledgerURL: appSupport.appendingPathComponent("ledger.jsonl"),
            autoFileThreshold: 0.85,
            fallbackFolder: "Other"
        )
    }

    /// List of candidate folder names — the direct subdirectories of `organizedRoot`,
    /// excluding the source folder itself (so the watched inbox isn't a valid file destination).
    /// Smith never invents folders; the user creates them under the organized root manually.
    public func candidateFolders() -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: organizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let sourcePath = sourceFolder.standardizedFileURL.path

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { $0.standardizedFileURL.path != sourcePath }
            .map { $0.lastPathComponent }
            .sorted()
    }
}
