import SwiftUI

/// Branch history shown in place of the file explorer tree.
///
/// Commit rows expand to the files each commit changed; selecting a file opens
/// a read-only snapshot of the file at that commit as a preview tab, and a
/// double click opens it persistently.
struct GitHistoryPane: View {
    @ObservedObject var model: GitHistoryModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                TreeView(
                    model: model.tree,
                    selectedID: model.selectedNodeID,
                    onToggle: { node in model.toggleNode(node) },
                    onSelect: { node in model.select(node, persistently: false) },
                    onDoubleSelect: { node in model.select(node, persistently: true) }
                ) { visualNode in
                    GitHistoryRow(model: model, node: visualNode.terminal)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text("Git History")
                    .font(.ui(.caption1))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
    }
}

private struct GitHistoryRow: View {
    @ObservedObject var model: GitHistoryModel
    let node: GitHistoryModel.Node

    var body: some View {
        switch node.value {
        case .commit(let commit):
            HStack(spacing: 6) {
                Image(systemName: "smallcircle.filled.circle")
                    .foregroundStyle(.secondary)
                Text(commit.label)
                    .lineLimit(1)
            }
            .help(model.commitTooltip(for: commit))
            .padding(.vertical, 3)
            .onAppear { model.requestCommitLog(for: commit) }
        case .file(_, let change):
            HStack(spacing: 6) {
                Text(change.kind.status)
                    .font(.ui(.caption1, weight: .semibold))
                    .foregroundStyle(statusColor(for: change.kind))
                Text(change.path)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let counts = changeCounts(change) {
                    Text(counts)
                        .font(.ui(.caption2))
                        .foregroundStyle(.secondary)
                }
            }
            .help(model.fileTooltip(for: change))
            .padding(.vertical, 3)
        case .info(let message):
            Text(message)
                .font(.ui(.body, italic: true))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.vertical, 3)
        }
    }

    private func changeCounts(_ change: GitFileChange) -> String? {
        guard !change.isBinary else { return "(+?,-?)" }
        guard change.additions != nil || change.deletions != nil else { return nil }
        let additions = change.additions.map(String.init) ?? "?"
        let deletions = change.deletions.map(String.init) ?? "?"
        return "(+\(additions),-\(deletions))"
    }

    private func statusColor(for kind: GitChangeKind) -> Color {
        switch kind {
        case .added, .untracked, .copied: .green
        case .deleted: .red
        case .conflicted: .purple
        default: .orange
        }
    }
}
