import SwiftUI
import SmithCore
import Models

struct ReviewQueueView: View {
    @EnvironmentObject var state: AppState
    @State private var folderOverrides: [UUID: String] = [:]

    var body: some View {
        if state.reviewQueue.isEmpty {
            Text("Nothing awaits review.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.reviewQueue) { item in
                        row(for: item)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    private func row(for item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "questionmark.diamond")
                    .foregroundStyle(.orange)
                Text(item.url.lastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text("→")
                    .font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: bindingFor(item)) {
                    ForEach(item.signals.candidateFolders, id: \.self) { folder in
                        Text(folder).tag(folder)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                Text("· suggested: \(item.suggestion.folder) (\(percentString(item.suggestion.confidence)))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Spacer()
                Button("Approve") {
                    let folder = folderOverrides[item.id] ?? item.suggestion.folder
                    state.approve(item, folder: folder)
                }
                .controlSize(.small)
                Button("Dismiss") {
                    state.dismiss(item)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func bindingFor(_ item: ReviewItem) -> Binding<String> {
        Binding(
            get: { folderOverrides[item.id] ?? item.suggestion.folder },
            set: { folderOverrides[item.id] = $0 }
        )
    }

    private func percentString(_ x: Double) -> String {
        "\(Int((x * 100).rounded()))%"
    }
}
