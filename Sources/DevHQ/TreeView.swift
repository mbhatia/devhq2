import SwiftUI

struct TreeContextMenuEntry: Identifiable {
    let id: String
    let title: String
    var isEnabled = true
    let action: () -> Void
}

/// A visual row formed from a maximal chain of single-child container nodes.
/// The source nodes remain unchanged; the first node provides row identity and
/// the last node provides expansion and child behavior.
struct FoldedTreeNode<ID: Hashable, Value>: Identifiable {
    let nodes: [TreeNode<ID, Value>]

    var id: ID { head.id }
    var head: TreeNode<ID, Value> { nodes[0] }
    var terminal: TreeNode<ID, Value> { nodes[nodes.count - 1] }
    var children: [TreeNode<ID, Value>]? { terminal.children }

    fileprivate init(head: TreeNode<ID, Value>, descendants: [TreeNode<ID, Value>]) {
        nodes = [head] + descendants
    }
}

func foldedTreeNodes<ID: Hashable, Value>(
    _ nodes: [TreeNode<ID, Value>],
    isContainer: (TreeNode<ID, Value>) -> Bool
) -> [FoldedTreeNode<ID, Value>] {
    nodes.map { head in
        var descendants: [TreeNode<ID, Value>] = []
        var terminal = head
        while isContainer(terminal),
              let children = terminal.children,
              children.count == 1,
              let child = children.first,
              isContainer(child) {
            descendants.append(child)
            terminal = child
        }
        return FoldedTreeNode(head: head, descendants: descendants)
    }
}

func mergedTreeContextMenuEntries<ID: Hashable, Value>(
    for node: FoldedTreeNode<ID, Value>,
    provider: (TreeNode<ID, Value>) -> [TreeContextMenuEntry]
) -> [TreeContextMenuEntry] {
    var entries: [TreeContextMenuEntry] = []
    var indexByID: [String: Int] = [:]
    for entry in node.nodes.flatMap(provider) {
        if let index = indexByID[entry.id] {
            entries[index] = entry
        } else {
            indexByID[entry.id] = entries.count
            entries.append(entry)
        }
    }
    return entries
}

struct TreeView<ID: Hashable, Value, RowContent: View>: View {
    @ObservedObject var model: TreeModel<ID, Value>
    let selectedID: ID?
    let onToggle: ((TreeNode<ID, Value>) -> Void)?
    let isContainer: (TreeNode<ID, Value>) -> Bool
    let isBranchSelectable: (TreeNode<ID, Value>) -> Bool
    let onSelect: (TreeNode<ID, Value>) -> Void
    let onDoubleSelect: ((TreeNode<ID, Value>) -> Void)?
    let contextMenuProvider: ((TreeNode<ID, Value>) -> [TreeContextMenuEntry])?
    @ViewBuilder let rowContent: (FoldedTreeNode<ID, Value>) -> RowContent

    init(
        model: TreeModel<ID, Value>,
        selectedID: ID?,
        onToggle: ((TreeNode<ID, Value>) -> Void)? = nil,
        isContainer: @escaping (TreeNode<ID, Value>) -> Bool = { $0.isBranch },
        isBranchSelectable: @escaping (TreeNode<ID, Value>) -> Bool = { _ in false },
        contextMenuProvider: ((TreeNode<ID, Value>) -> [TreeContextMenuEntry])? = nil,
        onSelect: @escaping (TreeNode<ID, Value>) -> Void,
        onDoubleSelect: ((TreeNode<ID, Value>) -> Void)? = nil,
        @ViewBuilder rowContent: @escaping (FoldedTreeNode<ID, Value>) -> RowContent
    ) {
        self.model = model
        self.selectedID = selectedID
        self.onToggle = onToggle
        self.isContainer = isContainer
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
            isContainer: isContainer,
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
    let isContainer: (TreeNode<ID, Value>) -> Bool
    let isBranchSelectable: (TreeNode<ID, Value>) -> Bool
    let onSelect: (TreeNode<ID, Value>) -> Void
    let onDoubleSelect: ((TreeNode<ID, Value>) -> Void)?
    let contextMenuProvider: ((TreeNode<ID, Value>) -> [TreeContextMenuEntry])?
    @ViewBuilder let rowContent: (FoldedTreeNode<ID, Value>) -> RowContent

    var body: some View {
        ForEach(foldedTreeNodes(nodes, isContainer: isContainer)) { visualNode in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Button {
                        toggle(visualNode.terminal)
                    } label: {
                        Image(systemName: disclosureIcon(for: visualNode.terminal))
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 12)
                            .foregroundStyle(.secondary)
                            .opacity(hasVisibleChildren(visualNode) ? 1 : 0)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasVisibleChildren(visualNode))

                    Button {
                        let terminal = visualNode.terminal
                        if isContainer(terminal), !isBranchSelectable(terminal) {
                            if hasVisibleChildren(visualNode) {
                                toggle(terminal)
                            }
                        } else {
                            onSelect(terminal)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            rowContent(visualNode)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            let terminal = visualNode.terminal
                            guard !isContainer(terminal) || isBranchSelectable(terminal) else {
                                return
                            }
                            onDoubleSelect?(terminal)
                        }
                    )
                }
                .padding(.leading, CGFloat(level * 14))
                .padding(.vertical, 2)
                .background(
                    visualNode.nodes.contains { $0.id == selectedID }
                        ? Color.accentColor.opacity(0.22)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .contextMenu {
                    if let contextMenuProvider {
                        ForEach(contextMenuEntries(
                            for: visualNode,
                            provider: contextMenuProvider
                        )) { entry in
                            Button(entry.title, action: entry.action)
                                .disabled(!entry.isEnabled)
                        }
                    }
                }

                if let children = visualNode.children,
                   !children.isEmpty,
                   model.isExpanded(visualNode.terminal) {
                    TreeRows(
                        nodes: children,
                        model: model,
                        selectedID: selectedID,
                        level: level + 1,
                        onToggle: onToggle,
                        isContainer: isContainer,
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

    private func hasVisibleChildren(_ node: FoldedTreeNode<ID, Value>) -> Bool {
        node.children?.isEmpty == false
    }

    private func toggle(_ node: TreeNode<ID, Value>) {
        if let onToggle {
            onToggle(node)
        } else {
            model.toggle(node)
        }
    }

    private func contextMenuEntries(
        for node: FoldedTreeNode<ID, Value>,
        provider: (TreeNode<ID, Value>) -> [TreeContextMenuEntry]
    ) -> [TreeContextMenuEntry] {
        mergedTreeContextMenuEntries(for: node, provider: provider)
    }
}
