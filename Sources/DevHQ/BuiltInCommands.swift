import AppKit
import Foundation

struct BuiltInCommandPickers {
    var repositoryURL: () -> URL?
    var fileURL: (_ workspaceRoot: URL) -> URL?
    var directoryURL: (_ workspaceRoot: URL) -> URL?

    static let appKit = BuiltInCommandPickers(
        repositoryURL: {
            let panel = NSOpenPanel()
            panel.title = "Add Local Git Repository"
            panel.prompt = "Add"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url : nil
        },
        fileURL: { workspaceRoot in
            let panel = NSSavePanel()
            panel.title = "New File"
            panel.prompt = "Create"
            panel.directoryURL = workspaceRoot
            panel.canCreateDirectories = true
            return panel.runModal() == .OK ? panel.url : nil
        },
        directoryURL: { workspaceRoot in
            let panel = NSSavePanel()
            panel.title = "New Directory"
            panel.prompt = "Create"
            panel.directoryURL = workspaceRoot
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "New Folder"
            return panel.runModal() == .OK ? panel.url : nil
        }
    )
}

@MainActor
func registerBuiltInCommands(
    in commandManager: CommandManager,
    workspace: WorkspaceModel,
    worktreeExplorer: WorktreeExplorerModel,
    pickers: BuiltInCommandPickers = .appKit
) throws {
    try commandManager.add(
        id: "worktree:add-repo",
        viewKinds: Set(CommandViewKind.allCases)
    ) { _ in
        guard let url = pickers.repositoryURL() else { return }
        do {
            try worktreeExplorer.addRepository(url)
        } catch {
            worktreeExplorer.clearError()
            throw error
        }
        worktreeExplorer.syncSelection(with: workspace.rootURL)
    }

    let workspaceAvailable: RegisteredCommand.Predicate = { _ in
        workspace.rootURL != nil
    }

    try commandManager.add(
        id: "file:new",
        viewKinds: [.file, .document],
        predicate: workspaceAvailable
    ) { _ in
        guard let rootURL = workspace.rootURL,
              let url = pickers.fileURL(rootURL) else { return }
        do {
            try workspace.createFile(at: url)
        } catch {
            workspace.errorMessage = nil
            throw error
        }
    }

    try commandManager.add(
        id: "file:new-dir",
        viewKinds: [.file, .document],
        predicate: workspaceAvailable
    ) { _ in
        guard let rootURL = workspace.rootURL,
              let url = pickers.directoryURL(rootURL) else { return }
        do {
            try workspace.createDirectory(at: url)
        } catch {
            workspace.errorMessage = nil
            throw error
        }
    }

    try commandManager.add(
        id: "file:close",
        viewKinds: [.document],
        predicate: { _ in workspace.selectedDocument != nil }
    ) { _ in
        workspace.closeSelected()
    }
}
