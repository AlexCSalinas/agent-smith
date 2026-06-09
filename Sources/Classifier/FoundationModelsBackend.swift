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
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
            Filename: \(signals.filename)
            Image labels: \(signals.imageLabels.joined(separator: ", "))
            Text in image:
            \(signals.ocrText.isEmpty ? "(no text)" : signals.ocrText)

            Existing folders (choose exactly one):
            \(signals.candidateFolders.map { "- \($0)" }.joined(separator: "\n"))
            """

        let response = try await session.respond(
            to: prompt,
            generating: _GenerableDecision.self
        ).content

        // Defend against the model picking a folder not in the candidate list.
        let folder = signals.candidateFolders.contains(response.folder)
            ? response.folder
            : (signals.candidateFolders.first ?? "")

        let confidence = signals.candidateFolders.contains(response.folder)
            ? response.confidence
            : 0.0  // model made one up — route to review

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
