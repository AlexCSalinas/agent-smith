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

    @Test func shouldConsider_acceptsBroadFileTypes() {
        // Default config is "process everything except blacklisted" — pdfs, archives,
        // documents, code, extensionless files all pass.
        let t = Triage()
        #expect(t.shouldConsider(tmpDir.appendingPathComponent("a.pdf")))
        #expect(t.shouldConsider(tmpDir.appendingPathComponent("a.zip")))
        #expect(t.shouldConsider(tmpDir.appendingPathComponent("a.docx")))
        #expect(t.shouldConsider(tmpDir.appendingPathComponent("a.txt")))
        #expect(t.shouldConsider(tmpDir.appendingPathComponent("a.swift")))
        #expect(t.shouldConsider(tmpDir.appendingPathComponent("README")))
    }

    @Test func shouldConsider_rejectsAppBundlesAndSystemFiles() {
        let t = Triage()
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("Safari.app")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("Some.bundle")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("Some.framework")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("Some.kext")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent(".DS_Store")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent(".localized")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("foo.icloud")))
    }

    @Test func shouldConsider_rejectsDotfilesAndPartials() {
        let t = Triage()
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent(".hidden.png")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("file.png.crdownload")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("file.png.part")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("file.png.tmp")))
    }

    @Test func shouldConsider_skipsActiveProjectFolders() throws {
        let project = tmpDir.appendingPathComponent("my-project", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        // Drop a `.git` marker.
        try fm.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let t = Triage()
        #expect(!t.shouldConsider(project), "folders containing .git must be left alone")
        #expect(t.looksLikeActiveProject(project))
    }

    @Test func shouldConsider_skipsProjectsWithVariousMarkers() throws {
        for marker in ["package.json", "Cargo.toml", "Package.swift", "go.mod", "Makefile"] {
            let project = tmpDir.appendingPathComponent("proj-\(marker)", isDirectory: true)
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            try Data().write(to: project.appendingPathComponent(marker))
            #expect(!Triage().shouldConsider(project), "marker \(marker) should mark folder as project")
        }
    }

    @Test func shouldConsider_acceptsFoldersWithoutProjectMarkers() throws {
        let folder = tmpDir.appendingPathComponent("just-pics", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("a.png"))
        try Data().write(to: folder.appendingPathComponent("b.png"))

        #expect(Triage().shouldConsider(folder), "ordinary folders with no project markers are fair game")
    }

    @Test func shouldConsider_whitelistModeOnlyAcceptsListedExtensions() {
        let t = Triage(config: Triage.Config(
            allowedExtensions: ["png", "jpg"]
        ))
        #expect(t.shouldConsider(tmpDir.appendingPathComponent("a.png")))
        #expect(t.shouldConsider(tmpDir.appendingPathComponent("a.jpg")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("a.pdf")))
        #expect(!t.shouldConsider(tmpDir.appendingPathComponent("a.zip")))
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

    @Test func waitForStability_returnsImmediatelyForDirectory() async throws {
        let dir = tmpDir.appendingPathComponent("aFolder", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let t = Triage()
        let start = ContinuousClock.now
        try await t.waitForStability(dir)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(50))
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
