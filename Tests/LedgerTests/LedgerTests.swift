import Foundation
import Testing
@testable import Ledger
@testable import Models

@Suite final class LedgerTests {
    let ledgerURL: URL
    let fm = FileManager.default

    init() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LedgerTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.ledgerURL = dir.appendingPathComponent("ledger.jsonl")
    }

    deinit {
        try? fm.removeItem(at: ledgerURL.deletingLastPathComponent())
    }

    private func makeMove(_ name: String) -> Move {
        Move(
            sourceURL: URL(fileURLWithPath: "/tmp/source/\(name)"),
            destinationURL: URL(fileURLWithPath: "/tmp/dest/\(name)"),
            decision: FolderDecision(folder: "dest", confidence: 0.9, reason: "")
        )
    }

    @Test func appendPersistsAcrossReload() async throws {
        let m1 = makeMove("a.png")
        let m2 = makeMove("b.png")

        do {
            let ledger = try Ledger(at: ledgerURL)
            try await ledger.append(m1)
            try await ledger.append(m2)
            let all = await ledger.all()
            #expect(all.map(\.id) == [m1.id, m2.id])
        }

        let reloaded = try Ledger(at: ledgerURL)
        let all = await reloaded.all()
        #expect(all.map(\.id) == [m1.id, m2.id])
    }

    @Test func recordUndoFoldsToLatestState() async throws {
        let ledger = try Ledger(at: ledgerURL)
        let m = makeMove("x.png")
        try await ledger.append(m)
        #expect(await ledger.get(m.id)?.undone == false)

        let undone = try await ledger.recordUndo(of: m.id)
        #expect(undone.undone)
        #expect(await ledger.get(m.id)?.undone == true)

        let reloaded = try Ledger(at: ledgerURL)
        #expect(await reloaded.get(m.id)?.undone == true)
        #expect((await reloaded.all()).count == 1)
    }

    @Test func recordUndoOfUnknownMoveThrows() async throws {
        let ledger = try Ledger(at: ledgerURL)
        let bogus = UUID()
        var caught = false
        do {
            _ = try await ledger.recordUndo(of: bogus)
        } catch let SmithError.undoFailed(reason) {
            caught = true
            #expect(reason.contains(bogus.uuidString))
        }
        #expect(caught)
    }

    @Test func recentReturnsNewestFirst() async throws {
        let ledger = try Ledger(at: ledgerURL)
        for i in 0..<5 {
            try await ledger.append(makeMove("f\(i).png"))
        }
        let recent = await ledger.recent(limit: 3)
        #expect(recent.count == 3)
        #expect(recent.first?.sourceURL.lastPathComponent == "f4.png")
        #expect(recent.last?.sourceURL.lastPathComponent == "f2.png")
    }

    @Test func movesInBatch_returnsOnlyThatBatch() async throws {
        let ledger = try Ledger(at: ledgerURL)
        let batchA = UUID()
        let batchB = UUID()
        let m1 = Move(
            sourceURL: URL(fileURLWithPath: "/x/a.png"),
            destinationURL: URL(fileURLWithPath: "/y/a.png"),
            decision: FolderDecision(folder: "y", confidence: 1, reason: ""),
            batchID: batchA
        )
        let m2 = Move(
            sourceURL: URL(fileURLWithPath: "/x/b.png"),
            destinationURL: URL(fileURLWithPath: "/y/b.png"),
            decision: FolderDecision(folder: "y", confidence: 1, reason: ""),
            batchID: batchA
        )
        let m3 = Move(
            sourceURL: URL(fileURLWithPath: "/x/c.png"),
            destinationURL: URL(fileURLWithPath: "/y/c.png"),
            decision: FolderDecision(folder: "y", confidence: 1, reason: ""),
            batchID: batchB
        )
        let solo = makeMove("solo.png")
        try await ledger.append(m1)
        try await ledger.append(m2)
        try await ledger.append(m3)
        try await ledger.append(solo)

        let inA = await ledger.moves(inBatch: batchA)
        #expect(inA.map(\.id) == [m1.id, m2.id])
        let inB = await ledger.moves(inBatch: batchB)
        #expect(inB.map(\.id) == [m3.id])
    }

    @Test func decode_oldLineWithoutBatchID_succeeds() throws {
        // Construct a pre-M8 ledger line by hand (no `batchID` key).
        let id = UUID()
        let timestamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_700_000_000))
        let oldLine = """
            {"id":"\(id.uuidString)","timestamp":"\(timestamp)","sourceURL":"file:///tmp/a.png","destinationURL":"file:///tmp/dest/a.png","decision":{"folder":"dest","confidence":0.9,"reason":"x"},"undone":false}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(Move.self, from: Data(oldLine.utf8))
        #expect(decoded.id == id)
        #expect(decoded.batchID == nil)
        #expect(decoded.undone == false)
    }

    @Test func appendOnlyOnDisk_undoAddsLineDoesNotRewriteHistory() async throws {
        let ledger = try Ledger(at: ledgerURL)
        let m = makeMove("y.png")
        try await ledger.append(m)
        _ = try await ledger.recordUndo(of: m.id)

        let data = try Data(contentsOf: ledgerURL)
        let lines = data.split(separator: 0x0A).filter { !$0.isEmpty }
        #expect(lines.count == 2)

        let dec = JSONDecoder.iso8601
        let originalLine = try dec.decode(Move.self, from: Data(lines[0]))
        let undoLine     = try dec.decode(Move.self, from: Data(lines[1]))
        #expect(!originalLine.undone)
        #expect(undoLine.undone)
        #expect(originalLine.id == undoLine.id)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
