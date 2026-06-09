import Foundation
import Models

/// The default classifier: tries Apple's on-device Foundation Models first (when available
/// on macOS 26+), falls back to a deterministic keyword-overlap heuristic otherwise.
///
/// Both backends obey Prime Directive 3 — they only ever return a folder from the
/// `candidateFolders` list. The heuristic, in particular, will return very low confidence
/// (which routes to the review queue) rather than inventing or guessing.
public struct LocalClassifier: FolderClassifier {
    private let foundationModelsBackend: FoundationModelsBackend?
    private let heuristic: HeuristicBackend

    public init() {
        self.foundationModelsBackend = FoundationModelsBackend.makeIfAvailable()
        self.heuristic = HeuristicBackend()
    }

    /// Test-only initializer that forces a specific backend mix.
    public init(foundationModels: FoundationModelsBackend?, heuristic: HeuristicBackend) {
        self.foundationModelsBackend = foundationModels
        self.heuristic = heuristic
    }

    public func classify(_ signals: FileSignals) async throws -> FolderDecision {
        // If we have FoundationModels, prefer it. Fall through to heuristic on any error
        // so a transient model failure doesn't strand the file.
        if let backend = foundationModelsBackend {
            do {
                let decision = try await backend.classify(signals)
                AppLog.classifier.info(
                    "fm: \(signals.filename, privacy: .public) → \(decision.folder, privacy: .public) @ \(decision.confidence, format: .fixed(precision: 2))"
                )
                return decision
            } catch {
                AppLog.classifier.error(
                    "FoundationModels failed (\(error.localizedDescription, privacy: .public)); falling back to heuristic"
                )
            }
        }

        let decision = heuristic.classify(signals)
        AppLog.classifier.info(
            "heur: \(signals.filename, privacy: .public) → \(decision.folder, privacy: .public) @ \(decision.confidence, format: .fixed(precision: 2))"
        )
        return decision
    }
}
