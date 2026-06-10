import Foundation
import Models

#if canImport(FoundationModels)
import FoundationModels

/// On-device LLM planner. Asks Apple's Foundation Models to cluster filenames into 3–7
/// short, generic subfolder names. The Curator then validates everything it returns —
/// filenames that don't exist are dropped, names with separators are dropped, clusters
/// below the min-file-count are dropped — so the planner's failure modes never leak.
public struct FoundationModelsTaxonomyPlanner: TaxonomyPlanner {
    private let instructions: String

    public init(instructions: String = Self.defaultInstructions) {
        self.instructions = instructions
    }

    public static let defaultInstructions = """
        You group filenames within a single category folder into a tidy taxonomy.
        Choose between 3 and 7 short, generic subfolder names in Title Case (e.g. "Uber",
        "Tax Documents"). Never use slashes or backslashes in names; never start with a
        dot. Only include a subfolder if it has at least 3 files. If files don't fit any
        good grouping, leave them out — do not force everything into a cluster.
        """

    public static func makeIfAvailable() -> FoundationModelsTaxonomyPlanner? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return FoundationModelsTaxonomyPlanner()
        default:
            return nil
        }
    }

    public func proposeTaxonomy(category: String, filenames: [String]) async throws -> RawTaxonomyPlan {
        let prompted = Self.truncateForPrompt(filenames)

        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
            Category: \(category)

            Files (group these into 3–7 subfolders):
            \(prompted.map { "- \($0)" }.joined(separator: "\n"))
            """

        let response = try await session.respond(
            to: prompt,
            generating: _GenerableTaxonomyPlan.self
        ).content

        let proposals = response.subfolders.map {
            RawSubfolderProposal(name: $0.name, files: $0.files, rationale: $0.rationale)
        }
        return RawTaxonomyPlan(subfolders: proposals)
    }
}

@Generable
private struct _GenerableTaxonomyPlan {
    @Guide(description: "3 to 7 subfolders. Short, generic, Title Case names.")
    let subfolders: [_GenerableSubfolderProposal]
}

@Generable
private struct _GenerableSubfolderProposal {
    @Guide(description: "Subfolder name, e.g. 'Uber', 'Tax Documents'")
    let name: String
    @Guide(description: "Filenames from the provided list that belong here")
    let files: [String]
    @Guide(description: "One short phrase explaining the grouping")
    let rationale: String
}

#else

/// Placeholder for SDKs without FoundationModels. The Curator is simply inactive on these
/// machines — `Curator.proposePlan` will surface the unavailability and bail rather than
/// produce a heuristic plan (taxonomy guesses without an LLM aren't valuable enough to be
/// worth the surface area).
public struct FoundationModelsTaxonomyPlanner: TaxonomyPlanner {
    public init() {}

    public static func makeIfAvailable() -> FoundationModelsTaxonomyPlanner? {
        AppLog.curator.info("FoundationModels not in this SDK; Curator inactive.")
        return nil
    }

    public func proposeTaxonomy(category: String, filenames: [String]) async throws -> RawTaxonomyPlan {
        throw SmithError.classifierUnavailable(reason: "FoundationModels framework requires macOS 26+")
    }
}
#endif

extension FoundationModelsTaxonomyPlanner {
    /// Soft cap on filenames sent in one prompt. Larger categories are truncated to fit
    /// the on-device context window. We accept that a single round-trip won't see every
    /// file in a very crowded category — repeated curator runs will surface a new plan
    /// for what's left after the first one is approved.
    static var promptBudget: Int { 120 }

    static func truncateForPrompt(_ filenames: [String]) -> [String] {
        guard filenames.count > promptBudget else { return filenames }
        return Array(filenames.prefix(promptBudget))
    }
}
