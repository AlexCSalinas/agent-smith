import Foundation
import Models

/// Deterministic keyword-overlap scorer. Used as the always-on fallback when Foundation
/// Models isn't available, and as the predictable backend in tests.
///
/// Algorithm: tokenize signals (filename + OCR text + image labels) and each candidate
/// folder name; score by Jaccard-like overlap with a folder-name-token weight. The winning
/// folder gets `confidence = min(0.9, score)`. If no signals overlap any folder, confidence
/// is low (~0.1) which deliberately routes to the review queue.
public struct HeuristicBackend: Sendable {
    public init() {}

    public func classify(_ signals: FileSignals) -> FolderDecision {
        guard !signals.candidateFolders.isEmpty else {
            return FolderDecision(folder: "", confidence: 0.0, reason: "no candidate folders provided")
        }

        let signalTokens = Self.tokenize(
            [signals.filename, signals.ocrText, signals.imageLabels.joined(separator: " ")].joined(separator: " ")
        )

        var best: (folder: String, score: Double, hits: Set<String>) = (signals.candidateFolders[0], 0.0, [])
        for folder in signals.candidateFolders {
            let folderTokens = Self.tokenize(folder)
            guard !folderTokens.isEmpty else { continue }

            // Match folder tokens against signal tokens with light substring fuzz so
            // simple plurals ("receipt" ↔ "receipts") and shared roots still hit.
            let hits: Set<String> = Set(folderTokens.filter { ft in
                signalTokens.contains { st in
                    st == ft
                        || (ft.count >= 4 && st.contains(ft))
                        || (st.count >= 4 && ft.contains(st))
                }
            })
            // Score: how many folder tokens are matched, weighted by folder specificity.
            let coverage = Double(hits.count) / Double(folderTokens.count)
            // Penalty for very short folder names (single letter) to avoid spurious matches.
            let lengthFactor = min(1.0, Double(folder.count) / 6.0)
            let score = coverage * lengthFactor

            if score > best.score {
                best = (folder, score, hits)
            }
        }

        let confidence = min(0.9, best.score)
        let reason: String = {
            if best.hits.isEmpty {
                return "no signal overlap with any folder name — review recommended"
            }
            return "matched: \(best.hits.sorted().joined(separator: ", "))"
        }()

        return FolderDecision(folder: best.folder, confidence: confidence, reason: reason)
    }

    /// Lowercase + strip non-alphanum + split. Drops tokens shorter than 3 characters
    /// (so "of", "to", "at" don't pollute the overlap score).
    static func tokenize(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let scalarsOK = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        let cleaned = String(scalarsOK)
        return Set(
            cleaned.split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 3 }
        )
    }
}
