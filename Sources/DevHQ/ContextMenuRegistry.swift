import Foundation
import SwiftUI

enum ContextMenuTarget: String, CaseIterable, Hashable {
    case worktreeRepository = "worktree.repository"
    case worktreeWorktree = "worktree.worktree"
    case fileDirectory = "file.directory"
    case fileFile = "file.file"

    var explorer: String {
        switch self {
        case .worktreeRepository, .worktreeWorktree: "worktree"
        case .fileDirectory, .fileFile: "file"
        }
    }

    var kind: String {
        switch self {
        case .worktreeRepository: "repository"
        case .worktreeWorktree: "worktree"
        case .fileDirectory: "directory"
        case .fileFile: "file"
        }
    }
}

/// A value snapshot captured when a context menu is opened. Actions never
/// receive the mutable explorer node itself.
struct ContextMenuSnapshot: Equatable {
    let target: ContextMenuTarget
    let name: String
    let path: String
    let repositoryName: String?
    let repositoryPath: String?
    let gitDirectoryPath: String?
    let worktreeName: String?
    let worktreePath: String?
    let isMainWorktree: Bool?

    init(
        target: ContextMenuTarget,
        name: String,
        path: String,
        repositoryName: String? = nil,
        repositoryPath: String? = nil,
        gitDirectoryPath: String? = nil,
        worktreeName: String? = nil,
        worktreePath: String? = nil,
        isMainWorktree: Bool? = nil
    ) {
        self.target = target
        self.name = name
        self.path = path
        self.repositoryName = repositoryName
        self.repositoryPath = repositoryPath
        self.gitDirectoryPath = gitDirectoryPath
        self.worktreeName = worktreeName
        self.worktreePath = worktreePath
        self.isMainWorktree = isMainWorktree
    }
}

struct ContextMenuItem: Identifiable {
    typealias Action = @MainActor (ContextMenuSnapshot) throws -> Void

    let id: String
    let title: String
    let targets: Set<ContextMenuTarget>
    let action: Action

    @MainActor
    func perform(with snapshot: ContextMenuSnapshot) throws {
        try action(snapshot)
    }
}

@MainActor
final class ContextMenuRegistry: ObservableObject {
    @Published private(set) var registeredItems: [ContextMenuItem] = []

    func add(
        id: String,
        title: String,
        targets: Set<ContextMenuTarget>,
        action: @escaping ContextMenuItem.Action
    ) {
        let item = ContextMenuItem(id: id, title: title, targets: targets, action: action)
        if let index = registeredItems.firstIndex(where: { $0.id == id }) {
            registeredItems[index] = item
        } else {
            registeredItems.append(item)
        }
    }

    @discardableResult
    func remove(id: String) -> Bool {
        guard let index = registeredItems.firstIndex(where: { $0.id == id }) else {
            return false
        }
        registeredItems.remove(at: index)
        return true
    }

    func items(for target: ContextMenuTarget) -> [ContextMenuItem] {
        registeredItems.filter { $0.targets.contains(target) }
    }
}
