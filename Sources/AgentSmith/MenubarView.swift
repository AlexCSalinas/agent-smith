import SwiftUI
import SmithCore
import Models

struct MenubarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statusLine
            Divider()
            sectionTitle("Review queue", count: state.reviewQueue.count)
            ReviewQueueView()
            Divider()
            sectionTitle("Curator plans", count: state.pendingPlans.count)
            CuratorPlansView()
            Divider()
            sectionTitle("Recent activity", count: state.recentMoves.count)
            ActivityFeedView()
            Spacer(minLength: 0)
            footer
        }
        .padding(12)
    }

    private var header: some View {
        HStack {
            Image(systemName: "tray.full")
            Text("Agent Smith")
                .font(.headline)
            Spacer()
            runStateBadge
        }
    }

    private var runStateBadge: some View {
        let (label, color): (String, Color) = {
            switch state.runState {
            case .stopped:        return ("stopped", .secondary)
            case .starting:       return ("starting…", .yellow)
            case .running:        return ("running", .green)
            case .errored:        return ("error", .red)
            }
        }()
        return Text(label)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var statusLine: some View {
        Text(state.lastEvent)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.subheadline.bold())
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("watching:")
                .font(.caption2).foregroundStyle(.secondary)
            Text(state.config.sourceFolder.path)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
    }
}
