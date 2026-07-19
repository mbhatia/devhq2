import SwiftUI

struct TreeView<ID: Hashable, Value, RowContent: View>: View {
    @ObservedObject var model: TreeModel<ID, Value>
    let selectedID: ID?
    let onSelect: (TreeNode<ID, Value>) -> Void
    @ViewBuilder let rowContent: (TreeNode<ID, Value>) -> RowContent

    var body: some View {
        TreeRows(
            nodes: model.roots,
            model: model,
            selectedID: selectedID,
            level: 0,
            onSelect: onSelect,
            rowContent: rowContent
        )
    }
}

private struct TreeRows<ID: Hashable, Value, RowContent: View>: View {
    let nodes: [TreeNode<ID, Value>]
    @ObservedObject var model: TreeModel<ID, Value>
    let selectedID: ID?
    let level: Int
    let onSelect: (TreeNode<ID, Value>) -> Void
    @ViewBuilder let rowContent: (TreeNode<ID, Value>) -> RowContent

    var body: some View {
        ForEach(nodes) { node in
            VStack(alignment: .leading, spacing: 1) {
                Button {
                    if node.isBranch {
                        model.toggle(node)
                    } else {
                        onSelect(node)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: disclosureIcon(for: node))
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 12)
                            .foregroundStyle(.secondary)
                            .opacity(node.isBranch ? 1 : 0)
                        rowContent(node)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(level * 14))
                    .padding(.vertical, 2)
                    .background(
                        node.id == selectedID
                            ? Color.accentColor.opacity(0.22)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let children = node.children, model.isExpanded(node) {
                    TreeRows(
                        nodes: children,
                        model: model,
                        selectedID: selectedID,
                        level: level + 1,
                        onSelect: onSelect,
                        rowContent: rowContent
                    )
                }
            }
        }
    }

    private func disclosureIcon(for node: TreeNode<ID, Value>) -> String {
        model.isExpanded(node) ? "chevron.down" : "chevron.right"
    }
}
