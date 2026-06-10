import Foundation
import Models

/// The Curator watches for "crowded" top-level categories and proposes a subfolder
/// taxonomy for them — but only ever as a suggestion. Folder creation (and the moves
/// that come with it) happens upstream in M8 after the user explicitly approves a plan.
///
/// Stateless w.r.t. plans: the orchestrator holds the pending list. Curator just
/// scans the filesystem and asks the planner for a proposal, then validates it.
public actor Curator {
    public struct Config: Sendable {
        public let organizedRoot: URL
        public let sourceFolder: URL
        public let crowdingThreshold: Int

        public init(organizedRoot: URL, sourceFolder: URL, crowdingThreshold: Int) {
            self.organizedRoot = organizedRoot
            self.sourceFolder = sourceFolder
            self.crowdingThreshold = crowdingThreshold
        }
    }

    private let config: Config
    private let planner: TaxonomyPlanner?
    private let now: @Sendable () -> Date

    public init(
        config: Config,
        planner: TaxonomyPlanner? = FoundationModelsTaxonomyPlanner.makeIfAvailable(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.planner = planner
        self.now = now
    }

    /// Walk top-level categories under `organizedRoot`, count loose files (depth-1, not
    /// subdirs), and return categories whose count meets the configured threshold.
    /// Excludes the source folder itself (which may equal organizedRoot in the Desktop layout).
    public func scanForCrowdedCategories() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: config.organizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let sourcePath = config.sourceFolder.standardizedFileURL.path
        var crowded: [String] = []

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if entry.standardizedFileURL.path == sourcePath { continue }
            let loose = looseFiles(in: entry).count
            if loose >= config.crowdingThreshold {
                crowded.append(entry.lastPathComponent)
            }
        }

        return crowded.sorted()
    }

    /// Ask the planner to propose a taxonomy for `category`, then run every deterministic
    /// validation rule. Returns `nil` if the planner is unavailable, the LLM call throws,
    /// or no cluster survives validation. The function NEVER touches the filesystem
    /// beyond reading it.
    public func proposePlan(for category: String) async -> CuratorPlan? {
        guard let planner else {
            AppLog.curator.info("planner unavailable; curator inactive")
            return nil
        }

        let categoryURL = config.organizedRoot.appendingPathComponent(category, isDirectory: true)
        let loose = looseFiles(in: categoryURL).map(\.lastPathComponent).sorted()
        guard loose.count >= config.crowdingThreshold else {
            AppLog.curator.info(
                "skip \(category, privacy: .public): only \(loose.count, privacy: .public) loose files"
            )
            return nil
        }

        let existingSubs = subfolders(in: categoryURL)

        let raw: RawTaxonomyPlan
        do {
            raw = try await planner.proposeTaxonomy(category: category, filenames: loose)
        } catch {
            AppLog.curator.error(
                "planner failed for \(category, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        return Self.validate(
            raw,
            category: category,
            existingFiles: Set(loose),
            existingSubfolders: existingSubs,
            now: now()
        )
    }

    // MARK: - Validation (deterministic, pure)

    /// Apply every post-LLM validation rule. `static` and pure so tests can hit it
    /// directly without spinning up the actor.
    public static func validate(
        _ raw: RawTaxonomyPlan,
        category: String,
        existingFiles: Set<String>,
        existingSubfolders: [String],
        now: Date = Date(),
        minFilesPerCluster: Int = 3
    ) -> CuratorPlan? {
        let normalizedExisting: [(normalized: String, original: String)] = existingSubfolders.map {
            (normalize(forMatch: $0), $0)
        }

        var claimedFiles = Set<String>()
        var validated: [SubfolderProposal] = []
        var usedNames = Set<String>()

        for cluster in raw.subfolders {
            // Normalize the proposed name.
            let trimmed = cluster.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !trimmed.contains("/"), !trimmed.contains("\\") else { continue }
            guard !trimmed.hasPrefix(".") else { continue }

            // Fuzzy-match against existing subfolders so repeated runs converge instead
            // of fragmenting ("Uber" + "ubers" + "UBER" all collapse onto whichever
            // already exists on disk, or onto the first canonical form).
            let normalized = normalize(forMatch: trimmed)
            let resolvedName: String = normalizedExisting
                .first(where: { $0.normalized == normalized })?
                .original ?? trimmed

            // Reject duplicate cluster names within the same plan.
            let dedupeKey = normalize(forMatch: resolvedName)
            guard !usedNames.contains(dedupeKey) else { continue }

            // Filter files: must exist as a loose file, must not already be claimed
            // by an earlier cluster (first-cluster-wins, matches the spec).
            let validFiles = cluster.files
                .filter { existingFiles.contains($0) }
                .filter { !claimedFiles.contains($0) }
                // De-duplicate within a single cluster too.
                .reduce(into: [String]()) { acc, f in if !acc.contains(f) { acc.append(f) } }

            guard validFiles.count >= minFilesPerCluster else { continue }

            for f in validFiles { claimedFiles.insert(f) }
            usedNames.insert(dedupeKey)
            validated.append(SubfolderProposal(
                name: resolvedName,
                files: validFiles,
                rationale: cluster.rationale
            ))
        }

        guard !validated.isEmpty else {
            AppLog.curator.info("validation produced no surviving clusters for \(category, privacy: .public)")
            return nil
        }

        return CuratorPlan(category: category, subfolders: validated, createdAt: now)
    }

    // MARK: - Internals

    /// Files (not subdirectories) directly inside `categoryURL`. Hidden files are skipped.
    private func looseFiles(in categoryURL: URL) -> [URL] {
        Self.looseFiles(in: categoryURL)
    }

    /// `static` mirror so validation paths can use it without crossing actor isolation.
    static func looseFiles(in categoryURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: categoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
        }
    }

    private func subfolders(in categoryURL: URL) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: categoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
    }

    /// Case- and punctuation-insensitive normalization for fuzzy matching subfolder
    /// names. "Tax Documents" / "tax-documents" / "TAX DOCUMENTS!" all → "taxdocuments".
    static func normalize(forMatch s: String) -> String {
        s.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { Character($0).lowercased() }
            .joined()
    }
}
