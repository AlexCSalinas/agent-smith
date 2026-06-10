import Foundation

/// A vetted, ready-to-apply taxonomy plan for one crowded category.
///
/// `CuratorPlan` is what the Curator surfaces to the user after deterministic post-LLM
/// validation. Approving it (M8) executes every `SubfolderProposal` as a Filer move under
/// a single `batchID` so the whole operation is undone with one click. Until then the plan
/// sits in the orchestrator's pending list — Smith never touches the user's files based on
/// a Curator suggestion without explicit approval.
public struct CuratorPlan: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Top-level category this plan applies to (e.g. `"Receipts"`). Always a single path
    /// component relative to `SmithConfig.organizedRoot`.
    public let category: String
    /// One entry per proposed subfolder. The validator guarantees: at least one entry,
    /// at least three files per entry, no duplicate file assignments, no path separators
    /// in names, no leading dots.
    public let subfolders: [SubfolderProposal]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        category: String,
        subfolders: [SubfolderProposal],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.subfolders = subfolders
        self.createdAt = createdAt
    }

    /// Total files this plan would move if approved.
    public var fileCount: Int { subfolders.reduce(0) { $0 + $1.files.count } }
}

/// One validated subfolder cluster within a `CuratorPlan`.
public struct SubfolderProposal: Sendable, Equatable {
    /// Subfolder name, a single path component (e.g. `"Uber"`).
    public let name: String
    /// Filenames (lastPathComponent only, no paths) that belong in this subfolder.
    /// Every name has been confirmed to exist as a loose file in the category.
    public let files: [String]
    /// One short phrase from the planner explaining the grouping. Surfaced in the UI.
    public let rationale: String

    public init(name: String, files: [String], rationale: String) {
        self.name = name
        self.files = files
        self.rationale = rationale
    }
}

/// Raw, untrusted output from a `TaxonomyPlanner` before Curator validation. The Curator
/// never returns one of these to the rest of the app — only `CuratorPlan`s, which have
/// passed every validation rule.
public struct RawTaxonomyPlan: Sendable, Equatable {
    public let subfolders: [RawSubfolderProposal]
    public init(subfolders: [RawSubfolderProposal]) {
        self.subfolders = subfolders
    }
}

public struct RawSubfolderProposal: Sendable, Equatable {
    public let name: String
    public let files: [String]
    public let rationale: String
    public init(name: String, files: [String], rationale: String) {
        self.name = name
        self.files = files
        self.rationale = rationale
    }
}
