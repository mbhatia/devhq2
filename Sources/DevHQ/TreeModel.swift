import Foundation

struct TreeNode<ID: Hashable, Value>: Identifiable {
    let id: ID
    let value: Value
    let children: [TreeNode]?

    var isBranch: Bool { children != nil }
}

@MainActor
final class TreeModel<ID: Hashable, Value>: ObservableObject {
    @Published private(set) var roots: [TreeNode<ID, Value>]
    @Published private(set) var expandedIDs: Set<ID>

    init(roots: [TreeNode<ID, Value>] = [], initiallyExpandedLevels: Int = 1) {
        self.roots = roots
        self.expandedIDs = Self.expandedIDs(
            in: roots,
            remainingLevels: initiallyExpandedLevels
        )
    }

    func replaceRoots(_ roots: [TreeNode<ID, Value>], initiallyExpandedLevels: Int = 1) {
        self.roots = roots
        expandedIDs = Self.expandedIDs(
            in: roots,
            remainingLevels: initiallyExpandedLevels
        )
    }

    func isExpanded(_ node: TreeNode<ID, Value>) -> Bool {
        expandedIDs.contains(node.id)
    }

    func toggle(_ node: TreeNode<ID, Value>) {
        guard node.isBranch else { return }
        if expandedIDs.contains(node.id) {
            expandedIDs.remove(node.id)
        } else {
            expandedIDs.insert(node.id)
        }
    }

    private static func expandedIDs(
        in nodes: [TreeNode<ID, Value>],
        remainingLevels: Int
    ) -> Set<ID> {
        guard remainingLevels > 0 else { return [] }
        var result = Set<ID>()
        for node in nodes where node.isBranch {
            result.insert(node.id)
            if let children = node.children {
                result.formUnion(expandedIDs(
                    in: children,
                    remainingLevels: remainingLevels - 1
                ))
            }
        }
        return result
    }
}
