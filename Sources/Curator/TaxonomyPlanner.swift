import Foundation

/// The Curator seam, mirroring `FolderClassifier` from M3. The default implementation is
/// `FoundationModelsTaxonomyPlanner`; tests inject a deterministic mock so validation logic
/// can be exercised without the LLM.
///
/// A planner returns a raw, untrusted plan. The Curator applies every validation rule
/// before promoting it to a `CuratorPlan`.
public protocol TaxonomyPlanner: Sendable {
    func proposeTaxonomy(category: String, filenames: [String]) async throws -> RawTaxonomyPlan
}
