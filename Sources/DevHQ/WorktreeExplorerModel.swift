import Foundation

enum WorktreeExplorerNodeID: Hashable {
    case repository(String)
    case worktree(String)
}

enum WorktreeExplorerNodeValue {
    case repository(GitRepositoryInfo)
    case worktree(GitWorktreeInfo)

    var name: String {
        switch self {
        case .repository(let repository): repository.name
        case .worktree(let worktree): worktree.name
        }
    }

    var url: URL {
        switch self {
        case .repository(let repository): repository.rootURL
        case .worktree(let worktree): worktree.url
        }
    }
}

typealias WorktreeNode = TreeNode<WorktreeExplorerNodeID, WorktreeExplorerNodeValue>

@MainActor
final class WorktreeExplorerModel: ObservableObject {
    enum ExplorerError: LocalizedError, Equatable {
        case duplicateRepository(String)

        var errorDescription: String? {
            switch self {
            case .duplicateRepository(let name):
                "\(name) is already in the worktree explorer."
            }
        }
    }

    @Published private(set) var repositories: [GitRepositoryInfo] = []
    @Published private(set) var selectedWorktreeID: String?
    @Published private(set) var errorMessage: String?
    let tree = TreeModel<WorktreeExplorerNodeID, WorktreeExplorerNodeValue>()

    var selectedNodeID: WorktreeExplorerNodeID? {
        selectedWorktreeID.map(WorktreeExplorerNodeID.worktree)
    }

    private let discoverer: any GitWorktreeDiscovering
    private let watcherFactory: RepositoryWatcherFactory
    private let onActivate: (GitWorktreeInfo) -> Void
    private let eventDelivery: (@escaping () -> Void) -> Void
    private var watchers: [String: any RepositoryWatching] = [:]

    init(
        discoverer: any GitWorktreeDiscovering,
        onActivate: @escaping (GitWorktreeInfo) -> Void,
        watcherFactory: @escaping RepositoryWatcherFactory = { url, onChange in
            try RepositoryWatcher(gitDirectoryURL: url, onChange: onChange)
        },
        eventDelivery: @escaping (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.async { action() }
        }
    ) {
        self.discoverer = discoverer
        self.onActivate = onActivate
        self.watcherFactory = watcherFactory
        self.eventDelivery = eventDelivery
    }

    deinit {
        watchers.values.forEach { $0.cancel() }
    }

    func addRepository(_ url: URL) throws {
        let repository: GitRepositoryInfo
        do {
            repository = try discoverer.discover(at: url)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }

        guard !repositories.contains(where: {
            canonicalPath($0.gitDirectoryURL) == canonicalPath(repository.gitDirectoryURL)
        }) else {
            let error = ExplorerError.duplicateRepository(repository.name)
            errorMessage = error.localizedDescription
            throw error
        }

        do {
            watchers[repository.id] = try makeWatcher(for: repository)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
        repositories.append(repository)
        errorMessage = nil
        rebuildTree()
    }

    func removeRepository(id: String) {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        let repository = repositories.remove(at: index)
        watchers.removeValue(forKey: repository.id)?.cancel()
        if let selectedWorktreeID,
           repository.worktrees.contains(where: { $0.id == selectedWorktreeID }) {
            self.selectedWorktreeID = nil
        }
        rebuildTree()
    }

    func activate(_ node: WorktreeNode) {
        guard case .worktree(let worktree) = node.value else { return }
        selectedWorktreeID = worktree.id
        onActivate(worktree)
    }

    /// Mirrors workspace changes that did not originate in the explorer, such
    /// as opening a folder from the toolbar or restoring a command-line path.
    func syncSelection(with workspaceURL: URL?) {
        guard let workspaceURL else {
            selectedWorktreeID = nil
            return
        }
        let workspacePath = canonicalPath(workspaceURL)
        selectedWorktreeID = repositories
            .lazy
            .flatMap(\.worktrees)
            .first { canonicalPath($0.url) == workspacePath }?
            .id
    }

    func clearError() {
        errorMessage = nil
    }

    func refreshAll() {
        for id in repositories.map(\.id) {
            refreshRepository(id: id)
        }
    }

    func refreshRepository(id: String) {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        let previous = repositories[index]
        do {
            let refreshed = try discoverer.discover(at: previous.rootURL)
            repositories[index] = refreshed

            if canonicalPath(previous.gitDirectoryURL) != canonicalPath(refreshed.gitDirectoryURL)
                || previous.id != refreshed.id {
                watchers.removeValue(forKey: previous.id)?.cancel()
                watchers[refreshed.id] = try makeWatcher(for: refreshed)
            }

            if let selectedWorktreeID,
               !repositories.contains(where: { repository in
                   repository.worktrees.contains(where: { $0.id == selectedWorktreeID })
               }) {
                self.selectedWorktreeID = nil
            }
            errorMessage = nil
            rebuildTree()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeWatcher(for repository: GitRepositoryInfo) throws -> any RepositoryWatching {
        try watcherFactory(repository.gitDirectoryURL) { [weak self] in
            self?.eventDelivery {
                self?.refreshRepository(id: repository.id)
            }
        }
    }

    private func rebuildTree() {
        let previousRootIDs = Set(tree.roots.map(\.id))
        let previouslyExpandedIDs = tree.expandedIDs
        let roots = repositories.map { repository in
            WorktreeNode(
                id: .repository(repository.id),
                value: .repository(repository),
                children: repository.worktrees.map { worktree in
                    WorktreeNode(
                        id: .worktree(worktree.id),
                        value: .worktree(worktree),
                        children: nil
                    )
                }
            )
        }
        tree.replaceRoots(roots, initiallyExpandedLevels: 1)
        // `replaceRoots` expands each root by default. Restore collapsed state
        // for repositories that already existed while leaving new ones open.
        for root in roots where previousRootIDs.contains(root.id)
            && !previouslyExpandedIDs.contains(root.id) {
            tree.toggle(root)
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
