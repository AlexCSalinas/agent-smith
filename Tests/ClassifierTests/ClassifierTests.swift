import Foundation
import Testing
@testable import Classifier
@testable import Models

@Suite struct ClassifierTests {
    @Test func heuristic_picksFolderWithBestTokenOverlap() {
        let signals = FileSignals(
            url: URL(fileURLWithPath: "/x/receipt-2026.png"),
            filename: "receipt-2026.png",
            byteSize: 100,
            ocrText: "Total $14.99 thank you for your purchase",
            imageLabels: ["document"],
            candidateFolders: ["Receipts", "Memes", "Screenshots", "Work"]
        )
        let decision = HeuristicBackend().classify(signals)
        #expect(decision.folder == "Receipts")
        #expect(decision.confidence > 0.0)
    }

    @Test func heuristic_returnsLowConfidenceWithNoOverlap() {
        let signals = FileSignals(
            url: URL(fileURLWithPath: "/x/IMG_1.png"),
            filename: "IMG_1.png",
            byteSize: 100,
            ocrText: "",
            imageLabels: [],
            candidateFolders: ["Receipts", "Memes"]
        )
        let decision = HeuristicBackend().classify(signals)
        #expect(decision.confidence < 0.5)
    }

    @Test func heuristic_handlesEmptyCandidates() {
        let signals = FileSignals(
            url: URL(fileURLWithPath: "/x/a.png"),
            filename: "a.png",
            byteSize: 100,
            ocrText: "",
            imageLabels: [],
            candidateFolders: []
        )
        let decision = HeuristicBackend().classify(signals)
        #expect(decision.confidence == 0.0)
    }

    @Test func localClassifier_fallsBackToHeuristic_whenFoundationModelsUnavailable() async throws {
        let signals = FileSignals(
            url: URL(fileURLWithPath: "/x/screenshot.png"),
            filename: "screenshot-meeting-notes.png",
            byteSize: 100,
            ocrText: "Meeting agenda",
            imageLabels: [],
            candidateFolders: ["Meetings", "Memes"]
        )
        let decision = try await LocalClassifier().classify(signals)
        #expect(decision.folder == "Meetings")
    }

    @Test func heuristic_isDeterministic() {
        let signals = FileSignals(
            url: URL(fileURLWithPath: "/x/work-doc.png"),
            filename: "work-doc.png",
            byteSize: 100,
            ocrText: "",
            imageLabels: [],
            candidateFolders: ["Work", "Personal"]
        )
        let backend = HeuristicBackend()
        #expect(backend.classify(signals) == backend.classify(signals))
    }
}
