import SwiftUI

struct TreeContextMenuEntry: Identifiable {
    let id: String
    let title: String
    var isEnabled = true
    let action: () -> Void
}

struct TreeView<ID: Hashable, Value, RowContent: View>: View {
    @ObservedObject var model: TreeModel<ID, Value>
    let selectedID: ID?
    let onToggle: ((TreeNode<ID, Value>) -> Void)?
    let isBranchSelectable: (TreeNode<ID, Value>) -> Bool
    let onSelect: (TreeNode<ID, Value>) -> Void
    let onDoubleSelect: ((TreeNode<ID, Value>) -> Void)?
    let contextMenuProvider: ((TreeNode<ID, Value>) -> [TreeContextMenuEntry])?
    @ViewBuilder let rowContent: (TreeNode<ID, Value>) -> RowContent

    init(
        model: TreeModel<ID, Value>,
        selectedID: ID?,
        onToggle: ((TreeNode<ID, Value>) -> Void)? = nil,
        isBranchSelectable: @escaping (TreeNode<ID, Value>) -> Bool = { _ in false },
        contextMenuProvider: ((TreeNode<ID, Value>) -> [TreeContextMenuEntry])? = nil,
        onSelect: @escaping (TreeNode<ID, Value>) -> Void,
        onDoubleSelect: ((TreeNode<ID, Value>) -> Void)? = nil,
        @ViewBuilder rowContent: @escaping (TreeNode<ID, Value>) -> RowContent
    ) {
        self.model = model
        self.selectedID = selectedID
        self.onToggle = onToggle
        self.isBranchSelectable = isBranchSelectable
        self.onSelect = onSelect
        self.onDoubleSelect = onDoubleSelect
        self.contextMenuProvider = contextMenuProvider
        self.rowContent = rowContent
    }

    var body: some View {
        TreeRows(
            nodes: model.roots,
            model: model,
            selectedID: selectedID,
            level: 0,
            onToggle: onToggle,
            isBranchSelectable: isBranchSelectable,
            onSelect: onSelect,
            onDoubleSelect: onDoubleSelect,
            contextMenuProvider: contextMenuProvider,
            rowContent: rowContent
        )
    }
}

private struct TreeRows<ID: Hashable, Value, RowContent: View>: View {
    let nodes: [TreeNode<ID, Value>]
    @ObservedObject var model: TreeModel<ID, Value>
    let selectedID: ID?
    let level: Int
    let onToggle: ((TreeNode<ID, Value>) -> Void)?
    let isBranchSelectable: (TreeNode<ID, Value>) -> Bool
    let onSelect: (TreeNode<ID, Value>) -> Void
    let onDoubleSelect: ((TreeNode<ID, Value>) -> Void)?
    let contextMenuProvider: ((TreeNode<ID, Value>) -> [TreeContextMenuEntry])?
    @ViewBuilder let rowContent: (TreeNode<ID, Value>) -> RowContent

    var body: some View {
        ForEach(nodes) { node in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Button {
                        toggle(node)
                    } label: {
                        Image(systemName: disclosureIcon(for: node))
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 12)
                            .foregroundStyle(.secondary)
                            .opacity(node.isBranch ? 1 : 0)
                    }
                    .buttonStyle(.plain)
                    .disabled(!node.isBranch)

                    Button {
                        if node.isBranch, !isBranchSelectable(node) {
                            toggle(node)
                        } else {
                            onSelect(node)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            rowContent(node)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            guard !node.isBranch || isBranchSelectable(node) else { return }
                            onDoubleSelect?(node)
                        }
                    )
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
                .contextMenu {
                    if let entries = contextMenuProvider?(node) {
                        ForEach(entries) { entry in
                            Button(entry.title, action: entry.action)
                                .disabled(!entry.isEnabled)
                        }
                    }
                }

                if let children = node.children, model.isExpanded(node) {
                    TreeRows(
                        nodes: children,
                        model: model,
                        selectedID: selectedID,
                        level: level + 1,
                        onToggle: onToggle,
                        isBranchSelectable: isBranchSelectable,
                        onSelect: onSelect,
                        onDoubleSelect: onDoubleSelect,
                        contextMenuProvider: contextMenuProvider,
                        rowContent: rowContent
                    )
                }
            }
        }
    }

    private func disclosureIcon(for node: TreeNode<ID, Value>) -> String {
        model.isExpanded(node) ? "chevron.down" : "chevron.right"
    }

    private func toggle(_ node: TreeNode<ID, Value>) {
        if let onToggle {
            onToggle(node)
        } else {
            model.toggle(node)
        }
    }
}
