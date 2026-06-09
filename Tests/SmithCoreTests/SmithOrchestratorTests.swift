import Foundation
import Testing
@testable import SmithCore
@testable import Models
@testable import Triage

/// Deterministic mock classifier so orchestrator tests don't depend on Vision OCR
/// or the heuristic's token scoring.
struct MockClassifier: FolderClassifier {
    let folder: String
    let confidence: Double
    func classify(_ signals: FileSignals) async throws -> FolderDecision {
        FolderDecision(folder: folder, confidence: confidence, reason: "mock")
    }
}

@Suite final class SmithOrchestratorTests {
    let tmpRoot: URL
    let fm = FileManager.default

    init() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SmithTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        self.tmpRoot = root
    }

    deinit {
        try? fm.removeItem(at: tmpRoot)
    }

    private func makeConfig(threshold: Double = 0.85) throws -> SmithConfig {
        let source = tmpRoot.appendingPathComponent("Desktop", isDirectory: true)
        let organized = tmpRoot.appendingPathComponent("Organized", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: organized.appendingPathComponent("Receipts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: organized.appendingPathComponent("Memes"), withIntermediateDirectories: true)
        return SmithConfig(
            sourceFolder: source,
            organizedRoot: organized,
            ledgerURL: tmpRoot.appendingPathComponent("ledger.jsonl"),
            autoFileThreshold: threshold
        )
    }

    private func makeFastTriage() -> Triage {
        Triage(config: Triage.Config(
            allowedExtensions: ["png", "jpg", "jpeg", "heic"],
            partialSuffixes: [".crdownload", ".download", ".part", ".tmp"],
            pollInterval: .milliseconds(20),
            requiredStablePolls: 2,
            stabilityTimeout: .seconds(2)
        ))
    }

    @Test func assimilate_filesAboveThreshold() async throws {
        let config = try makeConfig(threshold: 0.5)
        let orch = try SmithOrchestrator(
            config: config,
            classifier: MockClassifier(folder: "Receipts", confidence: 0.9),
            triage: makeFastTriage()
        )

        let file = config.sourceFolder.appendingPathComponent("a.png")
        try Data("payload".utf8).write(to: file)
        await orch.assimilate(file)

        #expect(!fm.fileExists(atPath: file.path))
        let dest = config.organizedRoot.appendingPathComponent("Receipts/a.png")
        #expect(fm.fileExists(atPath: dest.path))

        let moves = await orch.recentMoves(limit: 10)
        #expect(moves.count == 1)
        #expect(moves.first?.decision.folder == "Receipts")
    }

    @Test func assimilate_queuesBelowThreshold() async throws {
        let config = try makeConfig(threshold: 0.85)
        let orch = try SmithOrchestrator(
            config: config,
            classifier: MockClassifier(folder: "Receipts", confidence: 0.4),
            triage: makeFastTriage()
        )

        let file = config.sourceFolder.appendingPathComponent("uncertain.png")
        try Data("?".utf8).write(to: file)
        await orch.assimilate(file)

        #expect(fm.fileExists(atPath: file.path))
        let queue = await orch.currentReviewQueue()
        #expect(queue.count == 1)
        #expect(queue.first?.url == file)
    }

    @Test func approveReview_movesAndRecords() async throws {
        let config = try makeConfig(threshold: 0.99)
        let orch = try SmithOrchestrator(
            config: config,
            classifier: MockClassifier(folder: "Receipts", confidence: 0.5),
            triage: makeFastTriage()
        )

        let file = config.sourceFolder.appendingPathComponent("b.png")
        try Data("y".utf8).write(to: file)
        await orch.assimilate(file)

        let queue = await orch.currentReviewQueue()
        let item = try #require(queue.first)
        let move = try await orch.approveReview(item.id, intoFolder: "Memes")

        #expect(move.decision.folder == "Memes")
        #expect(fm.fileExists(atPath: config.organizedRoot.appendingPathComponent("Memes/b.png").path))
        #expect((await orch.currentReviewQueue()).isEmpty)
    }

    @Test func undo_restoresFile() async throws {
        let config = try makeConfig(threshold: 0.5)
        let orch = try SmithOrchestrator(
            config: config,
            classifier: MockClassifier(folder: "Receipts", confidence: 0.9),
            triage: makeFastTriage()
        )

        let file = config.sourceFolder.appendingPathComponent("c.png")
        try Data("z".utf8).write(to: file)
        await orch.assimilate(file)

        let move = try #require(await orch.recentMoves().first)
        #expect(!move.undone)

        _ = try await orch.undo(move.id)

        #expect(fm.fileExists(atPath: file.path))
        #expect(!fm.fileExists(atPath: move.destinationURL.path))
        let post = try #require(await orch.recentMoves().first)
        #expect(post.undone)
    }

    @Test func assimilate_skipsNonImage() async throws {
        let config = try makeConfig(threshold: 0.5)
        let orch = try SmithOrchestrator(
            config: config,
            classifier: MockClassifier(folder: "Receipts", confidence: 0.99),
            triage: makeFastTriage()
        )

        let file = config.sourceFolder.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: file)
        await orch.assimilate(file)

        #expect(fm.fileExists(atPath: file.path))
        #expect((await orch.currentReviewQueue()).isEmpty)
        #expect((await orch.recentMoves()).count == 0)
    }

    @Test func assimilate_skipsWhenNoCandidateFolders() async throws {
        let source = tmpRoot.appendingPathComponent("Desktop2", isDirectory: true)
        let organized = tmpRoot.appendingPathComponent("Empty", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: organized, withIntermediateDirectories: true)
        let config = SmithConfig(
            sourceFolder: source,
            organizedRoot: organized,
            ledgerURL: tmpRoot.appendingPathComponent("ledger2.jsonl"),
            autoFileThreshold: 0.5
        )
        let orch = try SmithOrchestrator(
            config: config,
            classifier: MockClassifier(folder: "X", confidence: 1.0),
            triage: makeFastTriage()
        )

        let file = source.appendingPathComponent("a.png")
        try Data("y".utf8).write(to: file)
        await orch.assimilate(file)

        #expect(fm.fileExists(atPath: file.path))
    }
}
