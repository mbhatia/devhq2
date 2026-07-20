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
        case .repository(let repository): repository.canonicalName
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
    private let onActivate: (GitRepositoryInfo, GitWorktreeInfo) -> Void
    private let onSelectionIdentityChange: (GitRepositoryInfo, GitWorktreeInfo) -> Void
    private let eventDelivery: (@escaping () -> Void) -> Void
    private let stateStore: (any WorkspaceStatePersisting)?
    private var watchers: [String: any RepositoryWatching] = [:]
    private var lastPersistedRepositories: [PersistedRepositoryState]?

    init(
        discoverer: any GitWorktreeDiscovering,
        onActivate: @escaping (GitRepositoryInfo, GitWorktreeInfo) -> Void,
        onSelectionIdentityChange: @escaping (GitRepositoryInfo, GitWorktreeInfo) -> Void = { _, _ in },
        stateStore: (any WorkspaceStatePersisting)? = nil,
        watcherFactory: @escaping RepositoryWatcherFactory = { url, onChange in
            try RepositoryWatcher(gitDirectoryURL: url, onChange: onChange)
        },
        eventDelivery: @escaping (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.async { action() }
        }
    ) {
        self.discoverer = discoverer
        self.onActivate = onActivate
        self.onSelectionIdentityChange = onSelectionIdentityChange
        self.stateStore = stateStore
        self.watcherFactory = watcherFactory
        self.eventDelivery = eventDelivery
    }

    convenience init(
        discoverer: any GitWorktreeDiscovering,
        onActivate: @escaping (GitWorktreeInfo) -> Void,
        onSelectionIdentityChange: @escaping (GitRepositoryInfo, GitWorktreeInfo) -> Void = { _, _ in },
        stateStore: (any WorkspaceStatePersisting)? = nil,
        watcherFactory: @escaping RepositoryWatcherFactory = { url, onChange in
            try RepositoryWatcher(gitDirectoryURL: url, onChange: onChange)
        },
        eventDelivery: @escaping (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.async { action() }
        }
    ) {
        self.init(
            discoverer: discoverer,
            onActivate: { _, worktree in onActivate(worktree) },
            onSelectionIdentityChange: onSelectionIdentityChange,
            stateStore: stateStore,
            watcherFactory: watcherFactory,
            eventDelivery: eventDelivery
        )
    }

    deinit {
        watchers.values.forEach { $0.cancel() }
    }

    func addRepository(_ url: URL) throws {
        let discoveredRepository: GitRepositoryInfo
        do {
            discoveredRepository = try discoverer.discover(at: url)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }

        guard !repositories.contains(where: {
            canonicalPath($0.gitDirectoryURL) == canonicalPath(discoveredRepository.gitDirectoryURL)
        }) else {
            let error = ExplorerError.duplicateRepository(discoveredRepository.name)
            errorMessage = error.localizedDescription
            throw error
        }

        let repository = discoveredRepository.withCanonicalName(
            allocateCanonicalName(for: discoveredRepository)
        )
        do {
            watchers[repository.id] = try makeWatcher(for: repository)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
        repositories.append(repository)
        errorMessage = nil
        rebuildTree()
        persistRepositories()
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
        persistRepositories()
    }

    func activate(_ node: WorktreeNode) {
        guard case .worktree(let worktree) = node.value else { return }
        guard let repository = repositories.first(where: { repository in
            repository.worktrees.contains(where: { $0.id == worktree.id })
        }) else { return }
        selectedWorktreeID = worktree.id
        persistRepositories()
        onActivate(repository, worktree)
    }

    /// Mirrors workspace changes that did not originate in the explorer, such
    /// as opening a folder from the toolbar or restoring a command-line path.
    func syncSelection(with workspaceURL: URL?) {
        let previousSelection = selectedWorktreeID
        guard let workspaceURL else {
            selectedWorktreeID = nil
            if previousSelection != nil { persistRepositories() }
            return
        }
        let workspacePath = canonicalPath(workspaceURL)
        selectedWorktreeID = repositories
            .lazy
            .flatMap(\.worktrees)
            .first { canonicalPath($0.url) == workspacePath }?
            .id
        if previousSelection != selectedWorktreeID { persistRepositories() }
    }

    func clearError() {
        errorMessage = nil
    }

    func refreshAll() {
        var refreshedAny = false
        for id in repositories.map(\.id) {
            refreshedAny = refreshRepository(id: id, shouldPersist: false) || refreshedAny
        }
        if refreshedAny { persistRepositories() }
    }

    func refreshRepository(id: String) {
        _ = refreshRepository(id: id, shouldPersist: true)
    }

    func toggle(_ node: WorktreeNode) {
        let wasExpanded = tree.isExpanded(node)
        tree.toggle(node)
        if wasExpanded != tree.isExpanded(node) {
            persistRepositories()
        }
    }

    /// Restores the persisted explorer in saved order while treating libgit2
    /// discovery as the authority for current worktree membership and names.
    /// The returned selection is useful to callers that need to defer opening
    /// it, for example while honoring an explicit command-line workspace.
    @discardableResult
    func restore(
        activateSelection: Bool = true
    ) -> (repository: GitRepositoryInfo, worktree: GitWorktreeInfo)? {
        guard let stateStore else { return nil }

        let savedRepositories: [PersistedRepositoryState]
        do {
            savedRepositories = try stateStore.loadRepositories()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        watchers.values.forEach { $0.cancel() }
        watchers.removeAll()
        repositories.removeAll()
        selectedWorktreeID = nil
        lastPersistedRepositories = savedRepositories

        var expansionByRootPath: [String: Bool] = [:]
        var selectedPath: String?
        var restorationError: Error?
        var validRepositoryIDs = Set<String>()

        for savedRepository in savedRepositories {
            expansionByRootPath[canonicalPath(
                URL(fileURLWithPath: savedRepository.rootPath, isDirectory: true)
            )] = savedRepository.isExpanded
            if selectedPath == nil {
                selectedPath = savedRepository.worktrees
                    .first(where: \.isSelected)
                    .map(\.path)
            }

            do {
                let discovered = try discoverer.discover(
                    at: URL(fileURLWithPath: savedRepository.rootPath, isDirectory: true)
                ).withCanonicalName(savedRepository.canonicalName)
                repositories.append(discovered)
                validRepositoryIDs.insert(discovered.id)
                do {
                    watchers[discovered.id] = try makeWatcher(for: discovered)
                } catch {
                    restorationError = error
                }
            } catch {
                restorationError = error
                repositories.append(staleRepository(from: savedRepository))
            }
        }

        rebuildTree()
        for root in tree.roots {
            guard case .repository(let repository) = root.value,
                  expansionByRootPath[canonicalPath(repository.rootURL)] == false,
                  tree.isExpanded(root) else { continue }
            tree.toggle(root)
        }

        let selectedIdentity = selectedPath.flatMap { path in
            let canonicalSelectedPath = canonicalPath(
                URL(fileURLWithPath: path, isDirectory: true)
            )
            return repositories.lazy.compactMap { repository in
                repository.worktrees.first(where: {
                    self.canonicalPath($0.url) == canonicalSelectedPath
                }).map { (repository: repository, worktree: $0) }
            }.first
        }
        selectedWorktreeID = selectedIdentity?.worktree.id
        errorMessage = restorationError?.localizedDescription
        persistRepositories()

        let validRestoredSelection = selectedIdentity.flatMap { identity in
            validRepositoryIDs.contains(identity.repository.id) ? identity : nil
        }
        if activateSelection, let restoredSelection = validRestoredSelection {
            onActivate(restoredSelection.repository, restoredSelection.worktree)
        }
        return validRestoredSelection
    }

    @discardableResult
    private func refreshRepository(id: String, shouldPersist: Bool) -> Bool {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return false }
        let previous = repositories[index]
        let wasExpanded = tree.expandedIDs.contains(.repository(previous.id))
        let previousSelectedWorktree = previous.worktrees.first(where: {
            $0.id == selectedWorktreeID
        })
        do {
            let refreshed = try discoverer.discover(at: previous.rootURL)
                .withCanonicalName(previous.canonicalName)

            if canonicalPath(previous.gitDirectoryURL) != canonicalPath(refreshed.gitDirectoryURL)
                || previous.id != refreshed.id
                || watchers[previous.id] == nil {
                let watcher = try makeWatcher(for: refreshed)
                watchers.removeValue(forKey: previous.id)?.cancel()
                watchers[refreshed.id] = watcher
            }
            repositories[index] = refreshed

            if let selectedWorktreeID,
               !repositories.contains(where: { repository in
                   repository.worktrees.contains(where: { $0.id == selectedWorktreeID })
               }) {
                self.selectedWorktreeID = nil
            }
            errorMessage = nil
            rebuildTree()
            if previous.id != refreshed.id,
               !wasExpanded,
               let refreshedRoot = tree.roots.first(where: {
                   $0.id == .repository(refreshed.id)
               }),
               tree.isExpanded(refreshedRoot) {
                tree.toggle(refreshedRoot)
            }
            if shouldPersist { persistRepositories() }
            if let previousSelectedWorktree,
               let refreshedSelectedWorktree = refreshed.worktrees.first(where: {
                   $0.id == previousSelectedWorktree.id
               }),
               previous.canonicalName != refreshed.canonicalName
                   || previousSelectedWorktree.name != refreshedSelectedWorktree.name {
                onSelectionIdentityChange(refreshed, refreshedSelectedWorktree)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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

    private func persistRepositories() {
        guard let stateStore else { return }
        let state = repositories.map { repository in
            let repositoryNodeID = WorktreeExplorerNodeID.repository(repository.id)
            return PersistedRepositoryState(
                canonicalName: repository.canonicalName,
                rootPath: canonicalPath(repository.rootURL),
                gitDirectoryPath: canonicalPath(repository.gitDirectoryURL),
                isExpanded: tree.expandedIDs.contains(repositoryNodeID),
                worktrees: repository.worktrees.map { worktree in
                    PersistedWorktreeState(
                        branchName: worktree.name,
                        path: canonicalPath(worktree.url),
                        isMain: worktree.isMain,
                        isExpanded: false,
                        isSelected: worktree.id == selectedWorktreeID
                    )
                }
            )
        }
        guard state != lastPersistedRepositories else { return }
        do {
            try stateStore.saveRepositories(state)
            lastPersistedRepositories = state
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func staleRepository(
        from state: PersistedRepositoryState
    ) -> GitRepositoryInfo {
        let rootURL = URL(fileURLWithPath: state.rootPath, isDirectory: true)
        return GitRepositoryInfo(
            rootURL: rootURL,
            name: rootURL.lastPathComponent,
            canonicalName: state.canonicalName,
            gitDirectoryURL: URL(
                fileURLWithPath: state.gitDirectoryPath,
                isDirectory: true
            ),
            worktrees: state.worktrees.map { worktree in
                GitWorktreeInfo(
                    name: worktree.branchName,
                    url: URL(fileURLWithPath: worktree.path, isDirectory: true),
                    isMain: worktree.isMain
                )
            }
        )
    }

    private func allocateCanonicalName(for repository: GitRepositoryInfo) -> String {
        let base = repository.rootURL.lastPathComponent.isEmpty
            ? repository.name
            : repository.rootURL.lastPathComponent
        let usedNames = Set(repositories.map { $0.canonicalName.lowercased() })
        guard usedNames.contains(base.lowercased()) else { return base }

        var suffix = 2
        while usedNames.contains("\(base)-\(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }
}
