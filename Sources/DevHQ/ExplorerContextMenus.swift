import AppKit
import Foundation

enum BuiltInContextMenuID {
    static let removeRepository = "devhq.worktree.remove-repository"
    static let createWorktree = "devhq.worktree.create"
    static let deleteWorktree = "devhq.worktree.delete"
    static let openInSystemViewer = "devhq.file.open-in-system-viewer"
}

enum ExplorerContextMenuError: LocalizedError {
    case repositoryUnavailable
    case worktreeUnavailable
    case cannotDeleteMainWorktree
    case unsavedChanges(URL)
    case couldNotOpen(URL)

    var errorDescription: String? {
        switch self {
        case .repositoryUnavailable:
            "The selected repository is no longer available."
        case .worktreeUnavailable:
            "The selected worktree is no longer available."
        case .cannotDeleteMainWorktree:
            "The main worktree cannot be deleted."
        case .unsavedChanges(let url):
            "Save or close unsaved documents in \(url.lastPathComponent) before removing it."
        case .couldNotOpen(let url):
            "Could not open \(url.path) in the system viewer."
        }
    }
}

@MainActor
func registerBuiltInContextMenus(
    in registry: ContextMenuRegistry,
    workspace: WorkspaceModel,
    worktreeExplorer: WorktreeExplorerModel,
    settings: EditorSettings,
    worktreeManager: any GitWorktreeManaging,
    promptForBranchName: @escaping @MainActor () -> String? = promptForWorktreeBranchName,
    openInSystemViewer: @escaping (URL, Bool) throws -> Void = openURLInSystemViewer
) {
    registry.add(
        id: BuiltInContextMenuID.removeRepository,
        title: "Remove Repository",
        targets: [.worktreeRepository]
    ) { snapshot in
        guard let repository = repository(for: snapshot, in: worktreeExplorer) else {
            throw ExplorerContextMenuError.repositoryUnavailable
        }
        if let activeURL = workspace.rootURL,
           repository.worktrees.contains(where: { sameFileURL($0.url, activeURL) }) {
            guard !workspace.hasUnsavedChanges(inWorkspaceAt: activeURL) else {
                throw ExplorerContextMenuError.unsavedChanges(activeURL)
            }
            workspace.closeWorkspace(at: activeURL)
        }
        worktreeExplorer.removeRepository(id: repository.id)
    }

    registry.add(
        id: BuiltInContextMenuID.createWorktree,
        title: "Create Worktree…",
        targets: [.worktreeRepository]
    ) { snapshot in
        guard let repository = repository(for: snapshot, in: worktreeExplorer) else {
            throw ExplorerContextMenuError.repositoryUnavailable
        }
        guard let branchName = promptForBranchName() else { return }
        let targetURL = worktreeCreationURL(
            repositoryRootURL: repository.rootURL,
            configuredPath: settings.gitWorktreePath,
            branchName: branchName
        )
        try worktreeManager.createWorktree(
            in: repository.rootURL,
            branchName: branchName,
            at: targetURL
        )
        worktreeExplorer.refreshRepository(id: repository.id)
    }

    registry.add(
        id: BuiltInContextMenuID.deleteWorktree,
        title: "Delete Worktree",
        targets: [.worktreeWorktree]
    ) { snapshot in
        guard let (repository, worktree) = worktree(
            for: snapshot,
            in: worktreeExplorer
        ) else {
            throw ExplorerContextMenuError.worktreeUnavailable
        }
        guard !worktree.isMain else {
            throw ExplorerContextMenuError.cannotDeleteMainWorktree
        }
        guard !workspace.hasUnsavedChanges(inWorkspaceAt: worktree.url) else {
            throw ExplorerContextMenuError.unsavedChanges(worktree.url)
        }
        try worktreeManager.deleteWorktree(
            in: repository.rootURL,
            at: worktree.url
        )
        workspace.closeWorkspace(at: worktree.url)
        worktreeExplorer.refreshRepository(id: repository.id)
    }

    registry.add(
        id: BuiltInContextMenuID.openInSystemViewer,
        title: "Open in System Viewer",
        targets: [.fileDirectory, .fileFile]
    ) { snapshot in
        try openInSystemViewer(
            URL(fileURLWithPath: snapshot.path),
            snapshot.target == .fileDirectory
        )
    }
}

func worktreeCreationURL(
    repositoryRootURL: URL,
    configuredPath: String,
    branchName: String
) -> URL {
    let expandedPath = NSString(string: configuredPath).expandingTildeInPath
    let baseURL: URL
    if expandedPath.hasPrefix("/") {
        baseURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
    } else {
        baseURL = repositoryRootURL.appendingPathComponent(expandedPath, isDirectory: true)
    }
    return baseURL.appendingPathComponent(branchName, isDirectory: true)
        .standardizedFileURL
}

@MainActor
func worktreeContextMenuSnapshot(
    for node: WorktreeNode,
    in explorer: WorktreeExplorerModel
) -> ContextMenuSnapshot? {
    switch node.value {
    case .repository(let repository):
        return ContextMenuSnapshot(
            target: .worktreeRepository,
            name: repository.canonicalName,
            path: repository.rootURL.path,
            repositoryName: repository.canonicalName,
            repositoryPath: repository.rootURL.path,
            gitDirectoryPath: repository.gitDirectoryURL.path
        )
    case .worktree(let selectedWorktree):
        guard let repository = explorer.repositories.first(where: { repository in
            repository.worktrees.contains(where: { $0.id == selectedWorktree.id })
        }) else { return nil }
        return ContextMenuSnapshot(
            target: .worktreeWorktree,
            name: selectedWorktree.name,
            path: selectedWorktree.url.path,
            repositoryName: repository.canonicalName,
            repositoryPath: repository.rootURL.path,
            gitDirectoryPath: repository.gitDirectoryURL.path,
            worktreeName: selectedWorktree.name,
            worktreePath: selectedWorktree.url.path,
            isMainWorktree: selectedWorktree.isMain
        )
    }
}

func fileContextMenuSnapshot(for node: FileNode) -> ContextMenuSnapshot {
    ContextMenuSnapshot(
        target: node.isDirectory ? .fileDirectory : .fileFile,
        name: node.name,
        path: node.url.path
    )
}

@MainActor
func treeContextMenuEntries(
    for snapshot: ContextMenuSnapshot,
    registry: ContextMenuRegistry,
    onError: @escaping (Error) -> Void
) -> [TreeContextMenuEntry] {
    registry.items(for: snapshot.target).map { item in
        TreeContextMenuEntry(
            id: item.id,
            title: item.title,
            isEnabled: item.id != BuiltInContextMenuID.deleteWorktree
                || snapshot.isMainWorktree != true
        ) {
            do {
                try item.perform(with: snapshot)
            } catch {
                onError(error)
            }
        }
    }
}

@MainActor
private func promptForWorktreeBranchName() -> String? {
    let branchField = NSTextField(string: "")
    branchField.placeholderString = "feature/my-branch"
    branchField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)

    let alert = NSAlert()
    alert.messageText = "Create Worktree"
    alert.informativeText = "Enter an existing or new local branch name."
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    alert.accessoryView = branchField
    alert.window.initialFirstResponder = branchField

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return branchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func openURLInSystemViewer(_ url: URL, isDirectory: Bool) throws {
    if isDirectory {
        guard NSWorkspace.shared.open(url) else {
            throw ExplorerContextMenuError.couldNotOpen(url)
        }
        return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.path]
    try process.run()
}

@MainActor
private func repository(
    for snapshot: ContextMenuSnapshot,
    in explorer: WorktreeExplorerModel
) -> GitRepositoryInfo? {
    explorer.repositories.first { repository in
        snapshot.gitDirectoryPath.map {
            sameFileURL(repository.gitDirectoryURL, URL(fileURLWithPath: $0))
        } ?? snapshot.repositoryPath.map {
            sameFileURL(repository.rootURL, URL(fileURLWithPath: $0))
        } ?? false
    }
}

@MainActor
private func worktree(
    for snapshot: ContextMenuSnapshot,
    in explorer: WorktreeExplorerModel
) -> (GitRepositoryInfo, GitWorktreeInfo)? {
    guard let repository = repository(for: snapshot, in: explorer),
          let worktreePath = snapshot.worktreePath else { return nil }
    let worktreeURL = URL(fileURLWithPath: worktreePath)
    guard let worktree = repository.worktrees.first(where: {
        sameFileURL($0.url, worktreeURL)
    }) else { return nil }
    return (repository, worktree)
}

private func sameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.resolvingSymlinksInPath().path
        == rhs.standardizedFileURL.resolvingSymlinksInPath().path
}
