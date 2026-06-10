import SwiftUI
import SmithCore
import Models

struct ActivityFeedView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.recentActivity.isEmpty {
            Text("No assimilations yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.recentActivity) { entry in
                        switch entry {
                        case .single(let move):
                            singleRow(for: move)
                        case .batch(let batchID, let category, let moves):
                            batchRow(batchID: batchID, category: category, moves: moves)
                        }
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    private func singleRow(for move: Move) -> some View {
        HStack(spacing: 8) {
            Image(systemName: move.undone ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                .foregroundStyle(move.undone ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(move.sourceURL.lastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Text("→ \(move.decision.folder) · \(percentString(move.decision.confidence))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !move.undone {
                Button("Undo") {
                    state.undo(move)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func batchRow(batchID: UUID, category: String, moves: [Move]) -> some View {
        let allUndone = moves.allSatisfy(\.undone)
        let subfolderCount = Set(moves.map(\.decision.folder)).count
        return HStack(spacing: 8) {
            Image(systemName: allUndone ? "arrow.uturn.backward.circle" : "folder.badge.gearshape")
                .foregroundStyle(allUndone ? Color.secondary : Color.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reorganized \(category) into \(subfolderCount) subfolder\(subfolderCount == 1 ? "" : "s")")
                    .font(.caption.bold())
                    .lineLimit(1)
                Text("\(moves.count) files\(allUndone ? " · undone" : "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !allUndone {
                Button("Undo all") {
                    state.undoBatch(batchID)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func percentString(_ x: Double) -> String {
        "\(Int((x * 100).rounded()))%"
    }
}
