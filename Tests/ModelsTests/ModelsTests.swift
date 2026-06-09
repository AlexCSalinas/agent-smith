import Foundation
import Testing
@testable import Models

@Suite struct ModelsTests {
    @Test func folderDecisionClampsConfidence() {
        #expect(FolderDecision(folder: "X", confidence: 1.5,  reason: "r").confidence == 1.0)
        #expect(FolderDecision(folder: "X", confidence: -0.2, reason: "r").confidence == 0.0)
        #expect(FolderDecision(folder: "X", confidence: 0.42, reason: "r").confidence == 0.42)
    }

    @Test func moveMarkingUndone() {
        let move = Move(
            sourceURL: URL(fileURLWithPath: "/tmp/a.png"),
            destinationURL: URL(fileURLWithPath: "/tmp/Receipts/a.png"),
            decision: FolderDecision(folder: "Receipts", confidence: 0.9, reason: "")
        )
        #expect(!move.undone)
        #expect(move.markingUndone().undone)
        #expect(move.id == move.markingUndone().id)
    }

    @Test func moveCodable() throws {
        let move = Move(
            sourceURL: URL(fileURLWithPath: "/tmp/a.png"),
            destinationURL: URL(fileURLWithPath: "/tmp/Receipts/a.png"),
            decision: FolderDecision(folder: "Receipts", confidence: 0.9, reason: "looks receipt-y")
        )
        let data = try JSONEncoder().encode(move)
        let decoded = try JSONDecoder().decode(Move.self, from: data)
        #expect(move == decoded)
    }
}
