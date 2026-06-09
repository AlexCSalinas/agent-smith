import SwiftUI
import SmithCore
import Models

struct ActivityFeedView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.recentMoves.isEmpty {
            Text("No assimilations yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.recentMoves) { move in
                        row(for: move)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    private func row(for move: Move) -> some View {
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

    private func percentString(_ x: Double) -> String {
        "\(Int((x * 100).rounded()))%"
    }
}
