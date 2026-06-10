import Foundation
import Models

#if canImport(FoundationModels)
import FoundationModels

/// On-device LLM classifier using Apple's Foundation Models framework (macOS 26+).
///
/// This file compiles only when `FoundationModels` is available in the SDK. On older SDKs
/// the type below is replaced by a placeholder whose `makeIfAvailable()` returns nil — so
/// `LocalClassifier` cleanly degrades to the heuristic.
public struct FoundationModelsBackend: Sendable {
    private let instructions: String

    public init(instructions: String = Self.defaultInstructions) {
        self.instructions = instructions
    }

    public static let defaultInstructions = """
        You file screenshots into one of the user's EXISTING folders.
        Only choose from the provided folder list. If nothing fits well,
        return low confidence — do not invent a folder.
        """

    /// Returns `nil` if Apple Intelligence isn't available on this machine
    /// (older hardware, Intelligence turned off, etc). The caller then falls back to heuristic.
    public static func makeIfAvailable() -> FoundationModelsBackend? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return FoundationModelsBackend()
        default:
            return nil
        }
    }

    public func classify(_ signals: FileSignals) async throws -> FolderDecision {
        let prompted = FoundationModelsBackend.truncate(signals.candidateFolders, to: FoundationModelsBackend.candidateBudget)

        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
            Filename: \(signals.filename)
            Image labels: \(signals.imageLabels.joined(separator: ", "))
            Text in image:
            \(signals.ocrText.isEmpty ? "(no text)" : signals.ocrText)

            Existing folders (choose exactly one, paths are relative — pick the most specific match):
            \(prompted.map { "- \($0)" }.joined(separator: "\n"))
            """

        let response = try await session.respond(
            to: prompt,
            generating: _GenerableDecision.self
        ).content

        // Off-list guard: the LLM only saw `prompted`, so accept only picks from that set.
        // If it invents or hallucinates a folder, force confidence to zero — the fallback /
        // review path then takes over upstream.
        let folder = prompted.contains(response.folder)
            ? response.folder
            : (prompted.first ?? "")

        let confidence = prompted.contains(response.folder) ? response.confidence : 0.0

        return FolderDecision(folder: folder, confidence: confidence, reason: response.reason)
    }

}

@Generable
private struct _GenerableDecision {
    @Guide(description: "Exact name of the best-fitting existing folder")
    let folder: String
    @Guide(description: "Confidence from 0.0 to 1.0")
    let confidence: Double
    @Guide(description: "One short phrase explaining the choice")
    let reason: String
}

#else

/// Placeholder for SDKs that don't ship FoundationModels yet (macOS < 26). On these
/// machines `makeIfAvailable()` returns nil so `LocalClassifier` falls back to the
/// heuristic backend. The seam is preserved so a macOS 26 build will light up the LLM
/// path with no source changes elsewhere.
public struct FoundationModelsBackend: Sendable {
    public init() {}

    public static func makeIfAvailable() -> FoundationModelsBackend? {
        AppLog.classifier.info("FoundationModels not in this SDK; using heuristic backend.")
        return nil
    }

    public func classify(_ signals: FileSignals) async throws -> FolderDecision {
        throw SmithError.classifierUnavailable(reason: "FoundationModels framework requires macOS 26+")
    }
}
#endif

extension FoundationModelsBackend {
    /// Soft ceiling on candidate entries sent to the on-device LLM. The Foundation Models
    /// context window is small; ~40 entries leaves room for filename, OCR text, and labels
    /// without blowing the budget. See DEVLOG ("Context budget for nested candidates").
    static var candidateBudget: Int { 40 }

    /// Pick a representative subset of `candidates` within the context budget. Top-level
    /// categories (no `/`) are always retained; subfolders are added round-robin per category
    /// until the cap is reached. Preserves the input order's relative ranking within each
    /// category so callers can prioritize via the sort coming out of `candidateFolders()`.
    ///
    /// Lives outside the `#if canImport(FoundationModels)` gate so it remains testable on
    /// SDKs that ship the placeholder backend.
    static func truncate(_ candidates: [String], to budget: Int) -> [String] {
        guard candidates.count > budget else { return candidates }

        var topLevel: [String] = []
        var subsByParent: [String: [String]] = [:]
        var parentOrder: [String] = []

        for c in candidates {
            if let slash = c.firstIndex(of: "/") {
                let parent = String(c[..<slash])
                if subsByParent[parent] == nil {
                    subsByParent[parent] = []
                    parentOrder.append(parent)
                }
                subsByParent[parent]?.append(c)
            } else {
                topLevel.append(c)
            }
        }

        var picked: [String] = topLevel
        // Round-robin across parents so no single crowded category eats the whole budget.
        var indices: [String: Int] = [:]
        while picked.count < budget {
            var addedThisPass = false
            for parent in parentOrder where picked.count < budget {
                let idx = indices[parent, default: 0]
                if let subs = subsByParent[parent], idx < subs.count {
                    picked.append(subs[idx])
                    indices[parent] = idx + 1
                    addedThisPass = true
                }
            }
            if !addedThisPass { break }
        }
        return picked
    }
}
