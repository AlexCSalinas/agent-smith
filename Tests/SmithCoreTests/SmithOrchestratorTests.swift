import Foundation
import Testing
@testable import SmithCore
@testable import Models
@testable import Triage
@testable import Curator

/// Deterministic mock classifier so orchestrator tests don't depend on Vision OCR
/// or the heuristic's token scoring.
struct MockClassifier: FolderClassifier {
    let folder: String
    let confidence: Double
    func classify(_ signals: FileSignals) async throws -> FolderDecision {
        FolderDecision(folder: folder, confidence: confidence, reason: "mock")
    }
}

/// Deterministic stand-in for the on-device taxonomy planner. Used by the orchestrator
/// curator-scan tests to make plan generation deterministic.
struct StubOrchPlanner: TaxonomyPlanner {
    let plan: RawTaxonomyPlan
    func proposeTaxonomy(category: String, filenames: [String]) async throws -> RawTaxonomyPlan {
        plan
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

    @Test func assimilate_lowConfidenceUsesFallbackFolder() async throws {
        let source = tmpRoot.appendingPathComponent("Desktop3", isDirectory: true)
        let organized = tmpRoot.appendingPathComponent("Organized3", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: organized.appendingPathComponent("Receipts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: organized.appendingPathComponent("Other"), withIntermediateDirectories: true)
        let config = SmithConfig(
            sourceFolder: source,
            organizedRoot: organized,
            ledgerURL: tmpRoot.appendingPathComponent("ledger3.jsonl"),
            autoFileThreshold: 0.85,
            fallbackFolder: "Other"
        )
        let orch = try SmithOrchestrator(
            config: config,
            classifier: MockClassifier(folder: "Receipts", confidence: 0.3),
            triage: makeFastTriage()
        )

        let file = source.appendingPathComponent("uncertain.png")
        try Data("?".utf8).write(to: file)
        await orch.assimilate(file)

        #expect(!fm.fileExists(atPath: file.path))
        #expect(fm.fileExists(atPath: organized.appendingPathComponent("Other/uncertain.png").path))
        #expect((await orch.currentReviewQueue()).isEmpty)

        let recent = await orch.recentMoves()
        #expect(recent.first?.decision.folder == "Other")
    }

    @Test func assimilate_movesAFolder() async throws {
        let source = tmpRoot.appendingPathComponent("Desktop4", isDirectory: true)
        let organized = tmpRoot.appendingPathComponent("Organized4", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: organized.appendingPathComponent("Work"), withIntermediateDirectories: true)
        let config = SmithConfig(
            sourceFolder: source,
            organizedRoot: organized,
            ledgerURL: tmpRoot.appendingPathComponent("ledger4.jsonl"),
            autoFileThreshold: 0.5
        )
        // Permissive triage (default config) so the folder isn't rejected by allowedExtensions.
        let orch = try SmithOrchestrator(
            config: config,
            classifier: MockClassifier(folder: "Work", confidence: 0.9),
            triage: Triage()
        )

        let folder = source.appendingPathComponent("ProjectFolder", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folder.appendingPathComponent("inner.txt"))

        await orch.assimilate(folder)

        #expect(!fm.fileExists(atPath: folder.path))
        let moved = organized.appendingPathComponent("Work/ProjectFolder")
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: moved.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(fm.fileExists(atPath: moved.appendingPathComponent("inner.txt").path))
    }

    @Test func assimilate_filesIntoNestedSubfolder() async throws {
        let source = tmpRoot.appendingPathComponent("DesktopN", isDirectory: true)
        let organized = tmpRoot.appendingPathComponent("OrganizedN", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: organized.appendingPathComponent("Receipts/Uber"), withIntermediateDirectories: true)
        try fm.createDirectory(at: organized.appendingPathComponent("Receipts/Amazon"), withIntermediateDirectories: true)
        let config = SmithConfig(
            sourceFolder: source,
            organizedRoot: organized,
            ledgerURL: tmpRoot.appendingPathComponent("ledgerN.jsonl"),
            autoFileThreshold: 0.5
        )
        let orch = try SmithOrchestrator(
            config: config,
            classifier: MockClassifier(folder: "Receipts/Uber", confidence: 0.9),
            triage: makeFastTriage()
        )

        let file = source.appendingPathComponent("trip.png")
        try Data("p".utf8).write(to: file)
        await orch.assimilate(file)

        let dest = organized.appendingPathComponent("Receipts/Uber/trip.png")
        #expect(fm.fileExists(atPath: dest.path))
        #expect(!fm.fileExists(atPath: file.path))

        // Round-trip undo against the nested destination.
        let move = try #require(await orch.recentMoves().first)
        _ = try await orch.undo(move.id)
        #expect(fm.fileExists(atPath: file.path))
        #expect(!fm.fileExists(atPath: dest.path))
    }

    @Test func candidateFolders_returnsDepth2RelativePaths() throws {
        let source = tmpRoot.appendingPathComponent("DesktopC", isDirectory: true)
        let organized = tmpRoot.appendingPathComponent("OrganizedC", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: organized.appendingPathComponent("Receipts/Uber"), withIntermediateDirectories: true)
        try fm.createDirectory(at: organized.appendingPathComponent("Receipts/Amazon"), withIntermediateDirectories: true)
        try fm.createDirectory(at: organized.appendingPathComponent("Memes"), withIntermediateDirectories: true)
        // Depth-3 entry — must NOT appear.
        try fm.createDirectory(at: organized.appendingPathComponent("Receipts/Uber/2024"), withIntermediateDirectories: true)
        // Hidden directory at depth 1 — must NOT appear.
        try fm.createDirectory(at: organized.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        let config = SmithConfig(
            sourceFolder: source,
            organizedRoot: organized,
            ledgerURL: tmpRoot.appendingPathComponent("ledgerC.jsonl")
        )

        let folders = config.candidateFolders()
        #expect(folders == [
            "Memes",
            "Receipts",
            "Receipts/Amazon",
            "Receipts/Uber"
        ])
    }

    @Test func candidateFolders_excludesSourceFolderWhenInsideOrganizedRoot() throws {
        // The Desktop layout: source == organizedRoot, with category folders sitting beside files.
        let shared = tmpRoot.appendingPathComponent("Desktop", isDirectory: true)
        try fm.createDirectory(at: shared.appendingPathComponent("Receipts/Uber"), withIntermediateDirectories: true)
        try fm.createDirectory(at: shared.appendingPathComponent("Memes"), withIntermediateDirectories: true)
        let config = SmithConfig(
            sourceFolder: shared,
            organizedRoot: shared,
            ledgerURL: tmpRoot.appendingPathComponent("ledgerS.jsonl")
        )
        let folders = config.candidateFolders()
        // Source IS organizedRoot, so we never see it as an entry. Its children appear normally.
        #expect(folders == ["Memes", "Receipts", "Receipts/Uber"])
    }

    @Test func runCuratorScan_emitsPlanForCrowdedCategoryAndStoresPending() async throws {
        let source = tmpRoot.appendingPathComponent("DesktopK", isDirectory: true)
        let organized = tmpRoot.appendingPathComponent("OrganizedK", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let receipts = organized.appendingPathComponent("Receipts", isDirectory: true)
        try fm.createDirectory(at: receipts, withIntermediateDirectories: true)
        for i in 0..<20 { try Data().write(to: receipts.appendingPathComponent("u\(i).png")) }

        let config = SmithConfig(
            sourceFolder: source,
            organizedRoot: organized,
            ledgerURL: tmpRoot.appendingPathComponent("ledgerK.jsonl"),
            autoFileThreshold: 0.5,
            crowdingThreshold: 20
        )

        let raw = RawTaxonomyPlan(subfolders: [
            RawSubfolderProposal(
                name: "Uber",
                files: (0..<10).map { "u\($0).png" },
                rationale: "uber rides"
            ),
        ])

        let orch = try SmithOrchestrator(
            config: config,
            classifier: MockClassifier(folder: "Receipts", confidence: 0.99),
            triage: makeFastTriage(),
            planner: StubOrchPlanner(plan: raw)
        )

        // Collect events emitted during the scan.
        let stream = orch.events
        let collected = Task<[SmithOrchestrator.Event], Never> {
            var out: [SmithOrchestrator.Event] = []
            for await event in stream {
                out.append(event)
                if case .curatorProposed = event.kind { break }
            }
            return out
        }

        await orch.runCuratorScan()
        let pending = await orch.currentPendingPlans()
        #expect(pending.count == 1)
        #expect(pending.first?.category == "Receipts")

        let events = await collected.value
        #expect(events.contains {
            if case .curatorProposed(let p) = $0.kind, p.category == "Receipts" { return true }
            return false
        })

        // Second scan is a no-op for the same category — no duplicate pending entry.
        await orch.runCuratorScan()
        #expect((await orch.currentPendingPlans()).count == 1)
    }

    @Test func dismissPlan_removesPendingEntry() async throws {
        let source = tmpRoot.appendingPathComponent("DesktopD", isDirectory: true)
        let organized = tmpRoot.appendingPathComponent("OrganizedD", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let receipts = organized.appendingPathComponent("Receipts", isDirectory: true)
        try fm.createDirectory(at: receipts, withIntermediateDirectories: true)
        for i in 0..<20 { try Data().write(to: receipts.appendingPathComponent("u\(i).png")) }

        let config = SmithConfig(
            sourceFolder: source,
            organizedRoot: organized,
            ledgerURL: tmpRoot.appendingPathComponent("ledgerD.jsonl"),
            crowdingThreshold: 20
        )
        let raw = RawTaxonomyPlan(subfolders: [
            RawSubfolderProposal(name: "Uber", files: (0..<5).map { "u\($0).png" }, rationale: ""),
        ])
        let orch = try SmithOrchestrator(
            config: config,
            classifier: MockClassifier(folder: "Receipts", confidence: 0.5),
            triage: makeFastTriage(),
            planner: StubOrchPlanner(plan: raw)
        )

        await orch.runCuratorScan()
        let plan = try #require(await orch.currentPendingPlans().first)
        await orch.dismissPlan(plan.id)
        #expect((await orch.currentPendingPlans()).isEmpty)
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
