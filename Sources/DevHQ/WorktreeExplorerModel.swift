import Foundation

enum WorktreeExplorerNodeID: Hashable {
    case repository(String)
    case worktree(String)
    case agent(AgentInstanceKey)
}

enum WorktreeExplorerNodeValue {
    case repository(GitRepositoryInfo)
    case worktree(GitWorktreeInfo)
    case agent(AgentRecord)

    var name: String {
        switch self {
        case .repository(let repository): repository.canonicalName
        case .worktree(let worktree): worktree.name
        case .agent(let agent):
            "\(agent.needsInput ? "! " : "")\(agent.name) [\(agent.profile)]"
        }
    }

    var url: URL {
        switch self {
        case .repository(let repository): repository.rootURL
        case .worktree(let worktree): worktree.url
        case .agent(let agent): agent.context.worktreeURL
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
    @Published private(set) var selectedAgentID: AgentInstanceKey?
    @Published private(set) var errorMessage: String?
    let tree = TreeModel<WorktreeExplorerNodeID, WorktreeExplorerNodeValue>()

    var selectedNodeID: WorktreeExplorerNodeID? {
        selectedAgentID.map(WorktreeExplorerNodeID.agent)
            ?? selectedWorktreeID.map(WorktreeExplorerNodeID.worktree)
    }

    private let discoverer: any GitWorktreeDiscovering
    private let watcherFactory: RepositoryWatcherFactory
    private let onActivate: (GitRepositoryInfo, GitWorktreeInfo) -> Void
    private let onSelectionIdentityChange: (GitRepositoryInfo, GitWorktreeInfo) -> Void
    private let eventDelivery: (@escaping () -> Void) -> Void
    private let stateStore: (any WorkspaceStatePersisting)?
    private let agentManager: AgentManager?
    private let onActivateAgent: (AgentRecord, GitRepositoryInfo, GitWorktreeInfo) throws -> Void
    private var watchers: [String: any RepositoryWatching] = [:]
    private var lastPersistedRepositories: [PersistedRepositoryState]?
    private var isRestoring = false

    init(
        discoverer: any GitWorktreeDiscovering,
        onActivate: @escaping (GitRepositoryInfo, GitWorktreeInfo) -> Void,
        onSelectionIdentityChange: @escaping (GitRepositoryInfo, GitWorktreeInfo) -> Void = { _, _ in },
        agentManager: AgentManager? = nil,
        onActivateAgent: @escaping (
            AgentRecord,
            GitRepositoryInfo,
            GitWorktreeInfo
        ) throws -> Void = { _, _, _ in },
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
        self.agentManager = agentManager
        self.onActivateAgent = onActivateAgent
        self.stateStore = stateStore
        self.watcherFactory = watcherFactory
        self.eventDelivery = eventDelivery
        agentManager?.onRecordsChanged = { [weak self] worktreeURL, _ in
            guard let self else { return }
            self.agentRecordsDidChange(in: worktreeURL)
        }
    }

    convenience init(
        discoverer: any GitWorktreeDiscovering,
        onActivate: @escaping (GitWorktreeInfo) -> Void,
        onSelectionIdentityChange: @escaping (GitRepositoryInfo, GitWorktreeInfo) -> Void = { _, _ in },
        agentManager: AgentManager? = nil,
        onActivateAgent: @escaping (
            AgentRecord,
            GitRepositoryInfo,
            GitWorktreeInfo
        ) throws -> Void = { _, _, _ in },
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
            agentManager: agentManager,
            onActivateAgent: onActivateAgent,
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
        agentManager?.removeAgents(in: repository)
        if let selectedWorktreeID,
           repository.worktrees.contains(where: { $0.id == selectedWorktreeID }) {
            self.selectedWorktreeID = nil
            selectedAgentID = nil
        }
        rebuildTree()
        persistRepositories()
    }

    func activate(_ node: WorktreeNode) {
        switch node.value {
        case .worktree(let worktree):
            activate(worktree)
        case .agent(let agent):
            activate(agent)
        case .repository:
            break
        }
    }

    private func activate(_ worktree: GitWorktreeInfo) {
        guard let repository = repositories.first(where: { repository in
            repository.worktrees.contains(where: { $0.id == worktree.id })
        }) else { return }
        selectedWorktreeID = worktree.id
        selectedAgentID = nil
        persistRepositories()
        onActivate(repository, worktree)
    }

    private func activate(_ agent: AgentRecord) {
        guard let (repository, worktree) = identity(forWorktreePath: agent.key.worktreePath)
        else { return }
        selectedWorktreeID = worktree.id
        selectedAgentID = agent.key
        persistRepositories()
        do {
            try onActivateAgent(agent, repository, worktree)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func profile(for agent: AgentRecord) -> AgentProfile? {
        agentManager?.profile(named: agent.profile)
    }

    /// Mirrors workspace changes that did not originate in the explorer, such
    /// as opening a folder from the toolbar or restoring a command-line path.
    func syncSelection(with workspaceURL: URL?) {
        let previousSelection = selectedWorktreeID
        guard let workspaceURL else {
            selectedWorktreeID = nil
            selectedAgentID = nil
            if previousSelection != nil { persistRepositories() }
            return
        }
        let workspacePath = canonicalPath(workspaceURL)
        selectedWorktreeID = repositories
            .lazy
            .flatMap(\.worktrees)
            .first { canonicalPath($0.url) == workspacePath }?
            .id
        if selectedAgentID?.worktreePath != workspacePath {
            selectedAgentID = nil
        }
        if previousSelection != selectedWorktreeID { persistRepositories() }
    }

    func clearError() {
        errorMessage = nil
    }

    func reportError(_ error: Error) {
        errorMessage = error.localizedDescription
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
        selectedAgentID = nil
        lastPersistedRepositories = savedRepositories
        isRestoring = true

        var expansionByRootPath: [String: Bool] = [:]
        var expansionByWorktreePath: [String: Bool] = [:]
        var savedWorktreesByPath: [String: PersistedWorktreeState] = [:]
        var selectedPath: String?
        var restorationError: Error?
        var validRepositoryIDs = Set<String>()

        for savedRepository in savedRepositories {
            expansionByRootPath[canonicalPath(
                URL(fileURLWithPath: savedRepository.rootPath, isDirectory: true)
            )] = savedRepository.isExpanded
            for worktree in savedRepository.worktrees {
                let path = canonicalPath(URL(
                    fileURLWithPath: worktree.path,
                    isDirectory: true
                ))
                expansionByWorktreePath[path] = worktree.isExpanded
                savedWorktreesByPath[path] = worktree
            }
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
                restoreAgents(in: discovered, savedWorktreesByPath: savedWorktreesByPath)
                do {
                    watchers[discovered.id] = try makeWatcher(for: discovered)
                } catch {
                    restorationError = error
                }
            } catch {
                restorationError = error
                let stale = staleRepository(from: savedRepository)
                repositories.append(stale)
                restoreAgents(in: stale, savedWorktreesByPath: savedWorktreesByPath)
            }
        }

        if let agentManager {
            let restoredWorktreePaths = Set(repositories.flatMap(\.worktrees).map {
                canonicalPath($0.url)
            })
            let missingWorktreeURLs = Set(agentManager.records.compactMap { record in
                restoredWorktreePaths.contains(record.key.worktreePath)
                    ? nil
                    : record.context.worktreeURL
            })
            for url in missingWorktreeURLs {
                agentManager.removeAgents(inWorktree: url)
            }
        }

        rebuildTree()
        var expandedIDs = Set<WorktreeExplorerNodeID>()
        for repository in repositories {
            if expansionByRootPath[canonicalPath(repository.rootURL)] == true {
                expandedIDs.insert(.repository(repository.id))
            }
            for worktree in repository.worktrees
                where expansionByWorktreePath[canonicalPath(worktree.url)] == true {
                expandedIDs.insert(.worktree(worktree.id))
            }
        }
        tree.restoreExpandedIDs(expandedIDs)

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
        isRestoring = false
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
        let previousWorktreePaths = Set(previous.worktrees.map { canonicalPath($0.url) })
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
            let refreshedPaths = Set(refreshed.worktrees.map { canonicalPath($0.url) })
            for removedPath in previousWorktreePaths.subtracting(refreshedPaths) {
                agentManager?.removeAgents(inWorktree: URL(fileURLWithPath: removedPath))
            }
            for worktree in refreshed.worktrees {
                let states = agentManager?.persistedAgents(for: worktree.url) ?? []
                agentManager?.restore(states, repository: refreshed, worktree: worktree)
            }

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
                    let agents = agentManager?.records(for: worktree.url) ?? []
                    return WorktreeNode(
                        id: .worktree(worktree.id),
                        value: .worktree(worktree),
                        children: agents.isEmpty ? nil : agents.map { agent in
                            WorktreeNode(
                                id: .agent(agent.key),
                                value: .agent(agent),
                                children: nil
                            )
                        }
                    )
                }
            )
        }
        tree.replaceRoots(roots, initiallyExpandedLevels: 0)
        var expandedIDs = previouslyExpandedIDs
        for root in roots where !previousRootIDs.contains(root.id) {
            expandedIDs.insert(root.id)
        }
        tree.restoreExpandedIDs(expandedIDs)
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
                        isExpanded: tree.expandedIDs.contains(.worktree(worktree.id)),
                        isSelected: worktree.id == selectedWorktreeID,
                        agents: agentManager?.persistedAgents(for: worktree.url) ?? []
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

    private func restoreAgents(
        in repository: GitRepositoryInfo,
        savedWorktreesByPath: [String: PersistedWorktreeState]
    ) {
        guard let agentManager else { return }
        for worktree in repository.worktrees {
            let state = savedWorktreesByPath[canonicalPath(worktree.url)]
            agentManager.restore(
                state?.agents ?? [],
                repository: repository,
                worktree: worktree
            )
        }
    }

    private func identity(
        forWorktreePath path: String
    ) -> (GitRepositoryInfo, GitWorktreeInfo)? {
        repositories.lazy.compactMap { repository in
            repository.worktrees.first(where: { self.canonicalPath($0.url) == path }).map {
                (repository, $0)
            }
        }.first
    }

    private func agentRecordsDidChange(in worktreeURL: URL) {
        let previousAgentIDs = Set(tree.roots.flatMap { repositoryNode in
            (repositoryNode.children ?? []).flatMap { worktreeNode in
                (worktreeNode.children ?? []).compactMap { node -> AgentInstanceKey? in
                    guard case .agent(let key) = node.id else { return nil }
                    return key
                }
            }
        })
        rebuildTree()
        let newAgents = (agentManager?.records(for: worktreeURL) ?? []).filter {
            !previousAgentIDs.contains($0.key)
        }
        if !isRestoring, let agent = newAgents.first {
            tree.reveal(.agent(agent.key))
        }
        guard !isRestoring else { return }
        if let selectedAgentID, agentManager?.record(for: selectedAgentID) == nil {
            self.selectedAgentID = nil
        }
        persistRepositories()
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
