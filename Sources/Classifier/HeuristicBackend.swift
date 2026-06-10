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
            // Nested paths like "Receipts/Uber" score primarily on the LAST component
            // ("Uber"), so a screenshot whose signal tokens include "uber" picks
            // Receipts/Uber over plain Receipts even though "Receipts" matches too.
            // For top-level folders the last component IS the whole path; parent tokens
            // are intentionally empty in that case so we don't double-count them.
            let segments = folder.split(separator: "/").map(String.init)
            let last = segments.last ?? folder
            let parentSegments = segments.dropLast()
            let lastTokens = Self.tokenize(last)
            let parentTokens = parentSegments.isEmpty
                ? Set<String>()
                : Self.tokenize(parentSegments.joined(separator: " "))
            let folderTokens = lastTokens.union(parentTokens)
            guard !folderTokens.isEmpty else { continue }

            // Match folder tokens against signal tokens with light substring fuzz so
            // simple plurals ("receipt" ↔ "receipts") and shared roots still hit.
            func matches(_ ft: String) -> Bool {
                signalTokens.contains { st in
                    st == ft
                        || (ft.count >= 4 && st.contains(ft))
                        || (st.count >= 4 && ft.contains(st))
                }
            }
            let lastHits = Set(lastTokens.filter(matches))
            let parentHits = Set(parentTokens.filter(matches))

            let lastCoverage = lastTokens.isEmpty ? 0 : Double(lastHits.count) / Double(lastTokens.count)
            let parentCoverage = parentTokens.isEmpty ? 0 : Double(parentHits.count) / Double(parentTokens.count)
            // Subfolder match dominates. For top-level folders parentCoverage is 0 by
            // construction, so the weight just becomes the lastCoverage.
            let coverage = parentTokens.isEmpty
                ? lastCoverage
                : (lastCoverage * 0.7 + parentCoverage * 0.3)
            // Penalty for very short overall folder paths (single-letter names) to avoid
            // spurious matches. Use the full path length so short subfolder names like
            // "Uber" still score well when nested under "Receipts".
            let lengthFactor = min(1.0, Double(folder.count) / 6.0)
            // Small nesting bonus so a confidently-matched subfolder beats its parent
            // when both match perfectly. The bonus is applied *after* lengthFactor so it
            // can push past 1.0 — the final confidence is still clamped by the caller
            // (min(0.9, …)). Without this, "Receipts/Uber" (1.0) and "Receipts" (1.0)
            // would tie and the strict `>` below would keep whichever came first.
            let nestingBonus = parentTokens.isEmpty ? 1.0 : 1.05
            let score = coverage * lengthFactor * nestingBonus
            let hits = lastHits.union(parentHits)

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
