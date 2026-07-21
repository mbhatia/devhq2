import AppKit
import Foundation

struct BuiltInCommandPickers {
    var repositoryURL: () -> URL?
    var remoteRepositorySpec: () -> String?
    var fileURL: (_ workspaceRoot: URL) -> URL?
    var directoryURL: (_ workspaceRoot: URL) -> URL?

    init(
        repositoryURL: @escaping () -> URL?,
        remoteRepositorySpec: @escaping () -> String? = { nil },
        fileURL: @escaping (_ workspaceRoot: URL) -> URL?,
        directoryURL: @escaping (_ workspaceRoot: URL) -> URL?
    ) {
        self.repositoryURL = repositoryURL
        self.remoteRepositorySpec = remoteRepositorySpec
        self.fileURL = fileURL
        self.directoryURL = directoryURL
    }

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
        remoteRepositorySpec: {
            let specField = NSTextField(string: "")
            specField.placeholderString = "server:/path/to/repo"
            specField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)

            let alert = NSAlert()
            alert.messageText = "Open Remote Repository"
            alert.informativeText = "Enter an SSH repository as server:/path/to/repo."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = specField
            alert.window.initialFirstResponder = specField

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return specField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
    pickers: BuiltInCommandPickers = .appKit,
    agentManager: AgentManager? = nil,
    agentProfiles: AgentProfileRegistry? = nil,
    agentCreationPrompt: AgentCreationPrompt? = nil
) throws {
    let agentCreationPrompt = agentCreationPrompt ?? .appKit
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

    try commandManager.add(
        id: "devhq:open-remote-repo",
        viewKinds: Set(CommandViewKind.allCases)
    ) { _ in
        guard let spec = pickers.remoteRepositorySpec() else { return }
        Task {
            try? await worktreeExplorer.addRemoteRepository(spec)
        }
    }

    try commandManager.add(
        id: "devhq:sync-remote-repos",
        viewKinds: Set(CommandViewKind.allCases)
    ) { _ in
        Task {
            await worktreeExplorer.synchronizeRemoteRepositories()
        }
    }

    let workspaceAvailable: RegisteredCommand.Predicate = { _ in
        workspace.rootURL != nil
    }

    try commandManager.add(
        id: "terminal:new",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: workspaceAvailable
    ) { _ in
        _ = try workspace.newTerminal()
    }

    try commandManager.add(
        id: "terminal:close",
        viewKinds: [.terminal],
        predicate: { _ in workspace.selectedTerminal != nil }
    ) { _ in
        guard let terminal = workspace.selectedTerminal else { return }
        workspace.close(terminal)
    }

    try commandManager.add(
        id: "agent:create",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: { context in
            guard agentManager != nil,
                  agentProfiles?.profiles.isEmpty == false else { return false }
            return agentWorktreeIdentity(
                for: context,
                workspace: workspace,
                explorer: worktreeExplorer
            ) != nil
        }
    ) { context in
        guard let agentManager, let agentProfiles,
              let identity = agentWorktreeIdentity(
                  for: context,
                  workspace: workspace,
                  explorer: worktreeExplorer
              ) else { return }
        let profileNames = agentProfiles.profiles.map(\.name).sorted()
        guard !profileNames.isEmpty,
              let request = agentCreationPrompt.present(profileNames) else { return }

        let record: AgentRecord
        do {
            record = try agentManager.create(
                profile: request.profile,
                name: request.name,
                repository: identity.repository,
                worktree: identity.worktree
            )
        } catch {
            workspace.errorMessage = error.localizedDescription
            return
        }
        if let node = agentNode(with: record.key, in: worktreeExplorer.tree.roots) {
            worktreeExplorer.activate(node)
        }
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

    try commandManager.add(
        id: "git:toggle-diff",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: workspaceAvailable
    ) { _ in
        workspace.isDiffOverlayEnabled.toggle()
    }

    for mode in FileExplorerFilterMode.allCases {
        try commandManager.add(
            id: "git:filter-\(mode.rawValue)",
            viewKinds: Set(CommandViewKind.allCases),
            predicate: workspaceAvailable
        ) { _ in
            workspace.selectFileFilter(mode)
        }
    }
}

@MainActor
private func agentWorktreeIdentity(
    for context: CommandContext,
    workspace: WorkspaceModel,
    explorer: WorktreeExplorerModel
) -> (repository: GitRepositoryInfo, worktree: GitWorktreeInfo)? {
    let activeURL = context.worktreeURL ?? workspace.rootURL
    if let activeURL,
       let identity = explorer.repositories.lazy.compactMap({ repository in
           repository.worktrees.first(where: { sameAgentWorktreeURL($0.url, activeURL) })
               .map { (repository, $0) }
       }).first {
        return identity
    }

    guard let selectedWorktreeID = explorer.selectedWorktreeID else { return nil }
    return explorer.repositories.lazy.compactMap { repository in
        repository.worktrees.first(where: { $0.id == selectedWorktreeID })
            .map { (repository, $0) }
    }.first
}

private func sameAgentWorktreeURL(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.resolvingSymlinksInPath().path
        == rhs.standardizedFileURL.resolvingSymlinksInPath().path
}

private func agentNode(
    with key: AgentInstanceKey,
    in nodes: [WorktreeNode]
) -> WorktreeNode? {
    for node in nodes {
        if node.id == .agent(key) { return node }
        if let children = node.children,
           let match = agentNode(with: key, in: children) {
            return match
        }
    }
    return nil
}
