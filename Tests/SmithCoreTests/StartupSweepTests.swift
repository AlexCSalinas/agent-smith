import Foundation
import Testing
@testable import SmithCore
@testable import Models
@testable import Triage

@Suite final class StartupSweepTests {
    let tmpRoot: URL
    let fm = FileManager.default

    init() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SweepTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        self.tmpRoot = root
    }

    deinit {
        try? fm.removeItem(at: tmpRoot)
    }

    @Test func startupSweepFilesPreExistingFiles() async throws {
        let source = tmpRoot.appendingPathComponent("Inbox", isDirectory: true)
        let organized = tmpRoot.appendingPathComponent("Organized", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: organized.appendingPathComponent("Receipts"), withIntermediateDirectories: true)

        // Pre-seed three files BEFORE the orchestrator starts.
        for name in ["one.png", "two.png", "three.png"] {
            try Data(name.utf8).write(to: source.appendingPathComponent(name))
        }

        let config = SmithConfig(
            sourceFolder: source,
            organizedRoot: organized,
            ledgerURL: tmpRoot.appendingPathComponent("ledger.jsonl"),
            autoFileThreshold: 0.5
        )
        let orch = try SmithOrchestrator(
            config: config,
            classifier: MockClassifier(folder: "Receipts", confidence: 0.9),
            triage: Triage(config: Triage.Config(
                allowedExtensions: ["png"],
                partialSuffixes: [".part", ".tmp"],
                pollInterval: .milliseconds(20),
                requiredStablePolls: 2,
                stabilityTimeout: .seconds(2)
            ))
        )

        try await orch.start()

        // Wait for the sweep to drain. Three files × ~50ms stability check each ≈ 150ms, give it room.
        try await Task.sleep(for: .milliseconds(1500))

        let dest = organized.appendingPathComponent("Receipts")
        let filed = try fm.contentsOfDirectory(atPath: dest.path)
        #expect(Set(filed) == Set(["one.png", "two.png", "three.png"]))
        #expect(try fm.contentsOfDirectory(atPath: source.path).isEmpty)

        await orch.stop()
    }
}
