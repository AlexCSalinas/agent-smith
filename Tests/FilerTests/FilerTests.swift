import Foundation
import Testing
@testable import Filer
@testable import Models

@Suite final class FilerTests {
    let tmpRoot: URL
    let source: URL
    let dest: URL
    let fm = FileManager.default

    init() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FilerTests-\(UUID().uuidString)", isDirectory: true)
        let src = root.appendingPathComponent("source", isDirectory: true)
        let dst = root.appendingPathComponent("dest", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        self.tmpRoot = root
        self.source = src
        self.dest = dst
    }

    deinit {
        try? fm.removeItem(at: tmpRoot)
    }

    @Test func move_filesSourceIntoDestination() throws {
        let file = source.appendingPathComponent("a.png")
        try Data("hello".utf8).write(to: file)

        let move = try Filer().move(
            file,
            intoDirectory: dest,
            decision: FolderDecision(folder: "dest", confidence: 0.9, reason: "")
        )

        #expect(!fm.fileExists(atPath: file.path))
        #expect(fm.fileExists(atPath: move.destinationURL.path))
        #expect(move.destinationURL.lastPathComponent == "a.png")
    }

    @Test func move_collisionRenamesNumerically() throws {
        // Pre-populate destination with a file of the name we'll collide with.
        try Data("first".utf8).write(to: dest.appendingPathComponent("a.png"))

        let filer = Filer()
        let decision = FolderDecision(folder: "dest", confidence: 0.9, reason: "")

        let f2 = source.appendingPathComponent("a.png")
        try Data("second".utf8).write(to: f2)
        let m2 = try filer.move(f2, intoDirectory: dest, decision: decision)
        #expect(m2.destinationURL.lastPathComponent == "a (2).png")

        let f3 = source.appendingPathComponent("a.png")
        try Data("third".utf8).write(to: f3)
        let m3 = try filer.move(f3, intoDirectory: dest, decision: decision)
        #expect(m3.destinationURL.lastPathComponent == "a (3).png")
    }

    @Test func move_neverOverwritesExistingFile() throws {
        let file = source.appendingPathComponent("important.png")
        try Data("source-contents".utf8).write(to: file)

        let existing = dest.appendingPathComponent("important.png")
        try Data("DO-NOT-OVERWRITE".utf8).write(to: existing)

        let move = try Filer().move(
            file,
            intoDirectory: dest,
            decision: FolderDecision(folder: "dest", confidence: 0.9, reason: "")
        )

        #expect(move.destinationURL != existing)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "DO-NOT-OVERWRITE")
        #expect(try String(contentsOf: move.destinationURL, encoding: .utf8) == "source-contents")
    }

    @Test func undo_movesFileBackToSource() throws {
        let file = source.appendingPathComponent("a.png")
        try Data("hello".utf8).write(to: file)

        let filer = Filer()
        let move = try filer.move(
            file,
            intoDirectory: dest,
            decision: FolderDecision(folder: "dest", confidence: 0.9, reason: "")
        )
        let undone = try filer.undo(move)

        #expect(undone.undone)
        #expect(fm.fileExists(atPath: file.path))
        #expect(!fm.fileExists(atPath: move.destinationURL.path))
    }

    @Test func undo_refusesToOverwriteAtSource() throws {
        let file = source.appendingPathComponent("a.png")
        try Data("original".utf8).write(to: file)

        let filer = Filer()
        let move = try filer.move(
            file,
            intoDirectory: dest,
            decision: FolderDecision(folder: "dest", confidence: 0.9, reason: "")
        )

        try Data("intruder".utf8).write(to: file)

        var caught = false
        do {
            _ = try filer.undo(move)
        } catch let SmithError.undoFailed(reason) {
            caught = true
            #expect(reason.contains("already exists"))
        }
        #expect(caught)

        // Both files still exist — undo did nothing destructive.
        #expect(fm.fileExists(atPath: move.destinationURL.path))
        #expect(try String(contentsOf: file, encoding: .utf8) == "intruder")
    }

    @Test func uniqueDestination_handlesNoExtension() throws {
        try Data().write(to: dest.appendingPathComponent("README"))
        let next = Filer.uniqueDestination(in: dest, for: "README")
        #expect(next.lastPathComponent == "README (2)")
    }
}
