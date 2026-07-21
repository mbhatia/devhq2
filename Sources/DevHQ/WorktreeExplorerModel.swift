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
        case .worktree(let worktree): worktree.displayName ?? worktree.name
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

    var tooltip: String {
        switch self {
        case .repository(let repository):
            guard let source = repository.remoteSource else { return repository.rootURL.path }
            return "\(source.specification) -> \(repository.rootURL.path)"
        case .worktree(let worktree):
            guard let remotePath = worktree.remotePath else { return worktree.url.path }
            return "\(remotePath) -> \(worktree.url.path)"
        case .agent(let agent):
            return agent.context.remoteWorktreePath.map {
                "\($0) -> \(agent.context.worktreeURL.path)"
            } ?? agent.context.worktreeURL.path
        }
    }
}

typealias WorktreeNode = TreeNode<WorktreeExplorerNodeID, WorktreeExplorerNodeValue>

@MainActor
final class WorktreeExplorerModel: ObservableObject {
    enum ExplorerError: LocalizedError, Equatable {
        case duplicateRepository(String)
        case remoteServiceUnavailable

        var errorDescription: String? {
            switch self {
            case .duplicateRepository(let name):
                "\(name) is already in the worktree explorer."
            case .remoteServiceUnavailable:
                "SSH remote repositories are unavailable."
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
    private let remoteService: (any SSHRemoteRepositoryServicing)?
    private let watcherFactory: RepositoryWatcherFactory
    private let onActivate: (GitRepositoryInfo, GitWorktreeInfo) -> Void
    private let onSelectionIdentityChange: (GitRepositoryInfo, GitWorktreeInfo) -> Void
    private let onWorktreeRemoved: (GitRepositoryInfo, GitWorktreeInfo) -> Void
    private let shouldSynchronizeRemoteRepository: (GitRepositoryInfo) -> Bool
    private let eventDelivery: (@escaping () -> Void) -> Void
    private let stateStore: (any WorkspaceStatePersisting)?
    private let agentManager: AgentManager?
    private let onActivateAgent: (AgentRecord, GitRepositoryInfo, GitWorktreeInfo) throws -> Void
    private var watchers: [String: any RepositoryWatching] = [:]
    private var lastPersistedRepositories: [PersistedRepositoryState]?
    private var isRestoring = false

    init(
        discoverer: any GitWorktreeDiscovering,
        remoteService: (any SSHRemoteRepositoryServicing)? = nil,
        onActivate: @escaping (GitRepositoryInfo, GitWorktreeInfo) -> Void,
        onSelectionIdentityChange: @escaping (GitRepositoryInfo, GitWorktreeInfo) -> Void = { _, _ in },
        onWorktreeRemoved: @escaping (GitRepositoryInfo, GitWorktreeInfo) -> Void = { _, _ in },
        shouldSynchronizeRemoteRepository: @escaping (GitRepositoryInfo) -> Bool = { _ in true },
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
        self.remoteService = remoteService
        self.onActivate = onActivate
        self.onSelectionIdentityChange = onSelectionIdentityChange
        self.onWorktreeRemoved = onWorktreeRemoved
        self.shouldSynchronizeRemoteRepository = shouldSynchronizeRemoteRepository
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
        remoteService: (any SSHRemoteRepositoryServicing)? = nil,
        onActivate: @escaping (GitWorktreeInfo) -> Void,
        onSelectionIdentityChange: @escaping (GitRepositoryInfo, GitWorktreeInfo) -> Void = { _, _ in },
        onWorktreeRemoved: @escaping (GitRepositoryInfo, GitWorktreeInfo) -> Void = { _, _ in },
        shouldSynchronizeRemoteRepository: @escaping (GitRepositoryInfo) -> Bool = { _ in true },
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
            remoteService: remoteService,
            onActivate: { _, worktree in onActivate(worktree) },
            onSelectionIdentityChange: onSelectionIdentityChange,
            onWorktreeRemoved: onWorktreeRemoved,
            shouldSynchronizeRemoteRepository: shouldSynchronizeRemoteRepository,
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

    /// Registers an SSH repository before doing any network work, then
    /// replaces its cached metadata only after a complete synchronization.
    func addRemoteRepository(_ specification: String) async throws {
        guard let remoteService else {
            let error = ExplorerError.remoteServiceUnavailable
            errorMessage = error.localizedDescription
            throw error
        }

        let source: SSHRemoteRepositorySource
        do {
            source = try remoteService.parseSource(specification)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
        guard !repositories.contains(where: {
            $0.remoteSource?.server == source.server
                && $0.remoteSource?.remotePath == source.remotePath
        }) else {
            let error = ExplorerError.duplicateRepository(source.remotePath)
            errorMessage = error.localizedDescription
            throw error
        }

        let mirrorURL = remoteService.mirrorPath(for: source)
        let repositoryName = remoteRepositoryName(source.remotePath)
        let placeholder = GitRepositoryInfo(
            rootURL: mirrorURL,
            name: repositoryName,
            canonicalName: allocateCanonicalName(base: repositoryName),
            gitDirectoryURL: mirrorURL.appendingPathComponent(".git", isDirectory: true),
            worktrees: [],
            remoteSource: source
        )
        repositories.append(placeholder)
        errorMessage = nil
        rebuildTree()
        persistRepositories()

        do {
            try await synchronizeRemoteRepository(source: source)
        } catch {
            throw error
        }
    }

    /// Synchronizes each remote independently. One failed host does not block
    /// successful metadata updates from other hosts.
    func synchronizeRemoteRepositories() async {
        let remoteRepositories = repositories.filter(\.isRemote)
        var sources: [(SSHRemoteRepositorySource, SSHRemoteSynchronizationContext)] = []
        var skippedSources: [SSHRemoteRepositorySource] = []
        for repository in remoteRepositories {
            guard let source = repository.remoteSource else { continue }
            if shouldSynchronizeRemoteRepository(repository) {
                sources.append((source, synchronizationContext(for: repository)))
            } else {
                skippedSources.append(source)
            }
        }
        var failures: [String] = []
        var cleanupWarnings: [String] = []
        await withTaskGroup(of: (SSHRemoteRepositorySource, Result<SSHRemoteRepositorySnapshot, Error>).self) { group in
            for (source, context) in sources {
                guard let remoteService else { continue }
                group.addTask {
                    do {
                        return (
                            source,
                            .success(try await remoteService.synchronize(source, context: context))
                        )
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            for await (source, result) in group {
                applyRemoteSynchronization(result, source: source)
                if case .failure(let error) = result {
                    failures.append("\(source.specification): \(error.localizedDescription)")
                } else if case .success(let snapshot) = result {
                    cleanupWarnings.append(contentsOf: snapshot.cleanupWarnings.map {
                        "\(source.specification): \($0)"
                    })
                }
            }
        }
        var notices: [String] = []
        if !failures.isEmpty {
            notices.append("Could not sync remote repositories: " + failures.sorted().joined(separator: "; "))
        }
        if !skippedSources.isEmpty {
            notices.append(
                "Skipped remote synchronization for "
                    + skippedSources.map(\.specification).sorted().joined(separator: ", ")
                    + " because of unsaved editor changes."
            )
        }
        if !cleanupWarnings.isEmpty {
            notices.append(
                "Remote synchronization completed with cleanup warnings: "
                    + cleanupWarnings.sorted().joined(separator: "; ")
            )
        }
        if !notices.isEmpty {
            errorMessage = notices.joined(separator: " ")
        }
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
        for id in repositories.filter({ !$0.isRemote }).map(\.id) {
            refreshedAny = refreshRepository(id: id, shouldPersist: false) || refreshedAny
        }
        if refreshedAny { persistRepositories() }
    }

    func refreshRepository(id: String) {
        guard repositories.first(where: { $0.id == id })?.remoteSource == nil else { return }
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
        var restoredRemoteError: String?
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

            if let server = savedRepository.server,
               let remotePath = savedRepository.remotePath,
               let source = try? SSHRemoteRepositorySource(
                   server: server,
                   remotePath: remotePath
               ) {
                let remote = staleRepository(
                    from: savedRepository,
                    remoteSource: source
                )
                repositories.append(remote)
                restoreAgents(in: remote, savedWorktreesByPath: savedWorktreesByPath)
                if restoredRemoteError == nil, let lastError = savedRepository.lastSyncError {
                    restoredRemoteError = "Could not sync remote repository \(source.specification): \(lastError)"
                }
                if FileManager.default.fileExists(atPath: remote.gitDirectoryURL.path) {
                    validRepositoryIDs.insert(remote.id)
                }
                continue
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
                expandedIDs.insert(visualRootID(for: repository))
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
        errorMessage = restorationError?.localizedDescription ?? restoredRemoteError
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
        let roots = repositoryGroups().map { group in
            let repository = group.first(where: { !$0.isRemote }) ?? group[0]
            let hasLocalAndRemoteSources = group.contains(where: { !$0.isRemote })
                && group.contains(where: \.isRemote)
            let displayRepository = hasLocalAndRemoteSources
                ? repository.withCanonicalName(repository.name)
                : repository
            return WorktreeNode(
                id: .repository(repository.id),
                value: .repository(displayRepository),
                children: group.flatMap(\.worktrees).map { worktree in
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

    private func repositoryGroups() -> [[GitRepositoryInfo]] {
        var groups: [[GitRepositoryInfo]] = []
        for repository in repositories {
            // Preserve separate roots for two local repositories that happen
            // to share a basename. SSH sources join the first matching group,
            // which gives local + remote repositories the requested shared
            // visual root without changing existing local-only behavior.
            let index = groups.firstIndex { group in
                guard group.first?.name == repository.name else { return false }
                return repository.isRemote || !group.contains(where: { !$0.isRemote })
            }
            if let index {
                groups[index].append(repository)
            } else {
                groups.append([repository])
            }
        }
        return groups
    }

    private func visualRootID(for repository: GitRepositoryInfo) -> WorktreeExplorerNodeID {
        let group = repositoryGroups().first(where: { group in
            group.contains(where: { $0.id == repository.id })
        }) ?? [repository]
        let representative = group.first(where: { !$0.isRemote }) ?? group[0]
        return .repository(representative.id)
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func persistRepositories() {
        guard let stateStore else { return }
        let state = repositories.map { repository in
            let repositoryNodeID = visualRootID(for: repository)
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
                        agents: agentManager?.persistedAgents(for: worktree.url) ?? [],
                        remotePath: worktree.remotePath
                    )
                },
                server: repository.remoteSource?.server,
                remotePath: repository.remoteSource?.remotePath,
                lastSyncError: repository.lastSyncError
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

    private func synchronizeRemoteRepository(
        source: SSHRemoteRepositorySource
    ) async throws {
        guard let repository = repositories.first(where: { $0.remoteSource == source }),
              shouldSynchronizeRemoteRepository(repository)
        else { return }
        guard let remoteService else {
            let error = ExplorerError.remoteServiceUnavailable
            applyRemoteSynchronization(.failure(error), source: source)
            throw error
        }
        do {
            let snapshot = try await remoteService.synchronize(
                source,
                context: synchronizationContext(for: repository)
            )
            applyRemoteSynchronization(.success(snapshot), source: source)
        } catch {
            applyRemoteSynchronization(.failure(error), source: source)
            throw error
        }
    }

    private func synchronizationContext(
        for repository: GitRepositoryInfo
    ) -> SSHRemoteSynchronizationContext {
        SSHRemoteSynchronizationContext(
            allowExistingCloneReferenceReuse: repository.worktrees.isEmpty
        )
    }

    private func applyRemoteSynchronization(
        _ result: Result<SSHRemoteRepositorySnapshot, Error>,
        source: SSHRemoteRepositorySource
    ) {
        guard let index = repositories.firstIndex(where: { $0.remoteSource == source }) else {
            return
        }
        let previous = repositories[index]
        switch result {
        case .success(let snapshot):
            let cleanupWarning = snapshot.cleanupWarnings.isEmpty
                ? nil
                : snapshot.cleanupWarnings.joined(separator: "; ")
            let refreshed = GitRepositoryInfo(
                rootURL: snapshot.rootURL,
                name: source.repositoryName,
                canonicalName: previous.canonicalName,
                gitDirectoryURL: snapshot.gitDirectoryURL,
                worktrees: snapshot.worktrees.map { worktree in
                    GitWorktreeInfo(
                        name: worktree.name,
                        url: worktree.localURL,
                        isMain: worktree.isMain,
                        remotePath: worktree.remotePath,
                        displayName: "[\(source.server)] \(worktree.name)"
                    )
                },
                remoteSource: source,
                lastSyncError: cleanupWarning
            )
            repositories[index] = refreshed
            watchers.removeValue(forKey: previous.id)?.cancel()
            errorMessage = cleanupWarning.map {
                "Remote synchronization completed with cleanup warnings: "
                    + "\(source.specification): \($0)"
            }
            restoreRemoteAgents(from: previous, into: refreshed)
            reconcileSelection(previous: previous, refreshed: refreshed)

        case .failure(let error):
            repositories[index] = GitRepositoryInfo(
                rootURL: previous.rootURL,
                name: previous.name,
                canonicalName: previous.canonicalName,
                gitDirectoryURL: previous.gitDirectoryURL,
                worktrees: previous.worktrees,
                remoteSource: source,
                lastSyncError: error.localizedDescription
            )
            errorMessage = error.localizedDescription
        }
        rebuildTree()
        persistRepositories()
    }

    private func restoreRemoteAgents(
        from previous: GitRepositoryInfo,
        into refreshed: GitRepositoryInfo
    ) {
        let previousPaths = Set(previous.worktrees.map { canonicalPath($0.url) })
        let refreshedPaths = Set(refreshed.worktrees.map { canonicalPath($0.url) })
        for removedPath in previousPaths.subtracting(refreshedPaths) {
            agentManager?.removeAgents(inWorktree: URL(fileURLWithPath: removedPath))
        }
        for worktree in refreshed.worktrees {
            let states = agentManager?.persistedAgents(for: worktree.url) ?? []
            agentManager?.restore(states, repository: refreshed, worktree: worktree)
        }
    }

    private func reconcileSelection(
        previous: GitRepositoryInfo,
        refreshed: GitRepositoryInfo
    ) {
        guard let selectedWorktreeID,
              previous.worktrees.contains(where: { $0.id == selectedWorktreeID })
        else { return }
        if let selected = refreshed.worktrees.first(where: { $0.id == selectedWorktreeID }) {
            onSelectionIdentityChange(refreshed, selected)
        } else {
            if let removed = previous.worktrees.first(where: { $0.id == selectedWorktreeID }) {
                onWorktreeRemoved(previous, removed)
            }
            self.selectedWorktreeID = nil
            selectedAgentID = nil
        }
    }

    private func remoteRepositoryName(_ remotePath: String) -> String {
        let name = URL(fileURLWithPath: remotePath).lastPathComponent
        return name.isEmpty ? "repo" : name
    }

    private func staleRepository(
        from state: PersistedRepositoryState,
        remoteSource: SSHRemoteRepositorySource? = nil
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
                    isMain: worktree.isMain,
                    remotePath: worktree.remotePath,
                    displayName: remoteSource.map {
                        "[\($0.server)] \(worktree.branchName)"
                    }
                )
            },
            remoteSource: remoteSource,
            lastSyncError: state.lastSyncError
        )
    }

    private func allocateCanonicalName(for repository: GitRepositoryInfo) -> String {
        let base = repository.rootURL.lastPathComponent.isEmpty
            ? repository.name
            : repository.rootURL.lastPathComponent
        return allocateCanonicalName(base: base)
    }

    private func allocateCanonicalName(base: String) -> String {
        let usedNames = Set(repositories.map { $0.canonicalName.lowercased() })
        guard usedNames.contains(base.lowercased()) else { return base }

        var suffix = 2
        while usedNames.contains("\(base)-\(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }
}
