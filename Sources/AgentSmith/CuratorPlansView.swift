import SwiftUI
import SmithCore
import Curator

struct CuratorPlansView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.pendingPlans.isEmpty {
            HStack(spacing: 6) {
                Text("No curator plans pending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Scan now") { state.runCuratorScan() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 6)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.pendingPlans) { plan in
                        row(for: plan)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    private func row(for plan: CuratorPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(.purple)
                Text("\(plan.category) → \(plan.subfolders.count) subfolder(s)")
                    .font(.caption.bold())
                Spacer()
                Text("\(plan.fileCount) files")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(plan.subfolders.enumerated()), id: \.offset) { _, sub in
                HStack {
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(sub.name) (\(sub.files.count))")
                        .font(.caption2)
                    Text("— \(sub.rationale)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack {
                Spacer()
                Button("Approve") { state.approvePlan(plan) }
                    .controlSize(.small)
                Button("Dismiss") { state.dismissPlan(plan) }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(Color.purple.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
