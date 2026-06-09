import Foundation
import Testing
@testable import Triage
@testable import Models

@Suite final class TriageTests {
    let tmpDir: URL
    let fm = FileManager.default

    init() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TriageTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tmpDir = dir
    }

    deinit {
        try? fm.removeItem(at: tmpDir)
    }

    @Test func shouldConsider_acceptsImageExtensions() {
        let t = Triage()
        for ext in ["png", "jpg", "jpeg", "heic", "PNG"] {
            let url = tmpDir.appendingPathComponent("file.\(ext)")
            #expect(t.shouldConsider(url))
        }
    }

    @Test func shouldConsider_rejectsNonImages() {
        let t = Triage()
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("a.pdf")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("a.zip")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("a")))
    }

    @Test func shouldConsider_rejectsDotfilesAndPartials() {
        let t = Triage()
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent(".hidden.png")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("file.png.crdownload")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("file.png.part")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("file.png.tmp")))
    }

    @Test func looksLikeMacScreenshot_matchesScreenshotFilenames() {
        let t = Triage()
        #expect(t.looksLikeMacScreenshot(URL(fileURLWithPath: "/x/Screenshot 2026-06-08 at 10.13.42 AM.png")))
        #expect(t.looksLikeMacScreenshot(URL(fileURLWithPath: "/x/Screenshot 2026-01-01.png")))
        #expect(!t.looksLikeMacScreenshot(URL(fileURLWithPath: "/x/IMG_4321.png")))
        #expect(!t.looksLikeMacScreenshot(URL(fileURLWithPath: "/x/random.png")))
    }

    @Test func waitForStability_returnsWhenFileSizeStops() async throws {
        let t = Triage(config: Triage.Config(
            allowedExtensions: ["png"],
            partialSuffixes: [".part"],
            pollInterval: .milliseconds(50),
            requiredStablePolls: 2,
            stabilityTimeout: .seconds(3)
        ))

        let file = tmpDir.appendingPathComponent("stable.png")
        try Data("done".utf8).write(to: file)

        let start = ContinuousClock.now
        try await t.waitForStability(file)
        let elapsed = ContinuousClock.now - start

        #expect(elapsed > .milliseconds(80))
        #expect(elapsed < .milliseconds(1500))
    }

    @Test func waitForStability_throwsWhenFileMissing() async throws {
        let t = Triage()
        let missing = tmpDir.appendingPathComponent("ghost.png")
        var caught = false
        do {
            try await t.waitForStability(missing)
        } catch let SmithError.fileNotFound(url) {
            caught = true
            #expect(url == missing)
        }
        #expect(caught)
    }

    @Test func waitForStability_timesOutOnGrowingFile() async throws {
        let t = Triage(config: Triage.Config(
            allowedExtensions: ["png"],
            partialSuffixes: [],
            pollInterval: .milliseconds(50),
            requiredStablePolls: 2,
            stabilityTimeout: .milliseconds(400)
        ))

        let file = tmpDir.appendingPathComponent("growing.png")
        try Data("a".utf8).write(to: file)

        let fileForWriter = file
        let writerTask = Task {
            while !Task.isCancelled {
                if let handle = try? FileHandle(forWritingTo: fileForWriter) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data("x".utf8))
                    try? handle.close()
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { writerTask.cancel() }

        var caught = false
        do {
            try await t.waitForStability(file)
        } catch let SmithError.fileNotStable(url) {
            caught = true
            #expect(url == file)
        }
        #expect(caught)
    }
}
