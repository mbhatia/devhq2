import Foundation
import XCTest
@testable import DevHQ

private final class FakeWorktreeDiscoverer: GitWorktreeDiscovering {
    var repositoriesByPath: [String: GitRepositoryInfo]

    init(_ repositories: [GitRepositoryInfo]) {
        repositoriesByPath = Dictionary(uniqueKeysWithValues: repositories.map {
            ($0.rootURL.standardizedFileURL.path, $0)
        })
    }

    func discover(at url: URL) throws -> GitRepositoryInfo {
        guard let repository = repositoriesByPath[url.standardizedFileURL.path] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return repository
    }
}

private final class FakeRepositoryWatcher: RepositoryWatching {
    let onChange: () -> Void
    private(set) var isCancelled = false

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func signalChange() {
        guard !isCancelled else { return }
        onChange()
    }

    func cancel() {
        isCancelled = true
    }
}

private final class FakeRepositoryWatcherFactory {
    private(set) var watchersByPath: [String: FakeRepositoryWatcher] = [:]

    func make(url: URL, onChange: @escaping () -> Void) -> any RepositoryWatching {
        let watcher = FakeRepositoryWatcher(onChange: onChange)
        watchersByPath[url.standardizedFileURL.path] = watcher
        return watcher
    }

    func watcher(for url: URL) -> FakeRepositoryWatcher? {
        watchersByPath[url.standardizedFileURL.path]
    }
}

private final class FakeWorkspaceStateStore: WorkspaceStatePersisting {
    var loadedRepositories: [PersistedRepositoryState] = []
    private(set) var repositoryWrites: [[PersistedRepositoryState]] = []

    func loadRepositories() throws -> [PersistedRepositoryState] {
        loadedRepositories
    }

    func saveRepositories(_ repositories: [PersistedRepositoryState]) throws {
        repositoryWrites.append(repositories)
    }

    func loadWorkspaceState(
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws -> PersistedWorkspaceState? {
        nil
    }

    func saveWorkspaceState(
        _ state: PersistedWorkspaceState,
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws {}
}

@MainActor
private final class ExplorerAgentPatternMatcher: LuaPatternMatching {
    func firstCapture(in text: String, pattern: String) throws -> String? { nil }
}

final class WorktreeExplorerModelTests: XCTestCase {
    @MainActor
    func testRestoresSanitizedDormantAgentsUnderExpandedWorktree() throws {
        let current = repository(
            at: "/repos/project",
            worktrees: [worktree("main", at: "/repos/project", isMain: true)]
        )
        let store = FakeWorkspaceStateStore()
        store.loadedRepositories = [PersistedRepositoryState(
            canonicalName: "project",
            rootPath: current.rootURL.path,
            gitDirectoryPath: current.gitDirectoryURL.path,
            isExpanded: true,
            worktrees: [PersistedWorktreeState(
                branchName: "main",
                path: current.rootURL.path,
                isMain: true,
                isExpanded: true,
                isSelected: false,
                agents: [
                    PersistedAgentState(
                        profile: "codex",
                        name: "  reviewer  ",
                        needsInput: true,
                        threadID: "thread-1"
                    ),
                    PersistedAgentState(
                        profile: "codex",
                        name: "reviewer",
                        needsInput: false,
                        threadID: nil
                    ),
                    PersistedAgentState(
                        profile: " ",
                        name: "ignored",
                        needsInput: false,
                        threadID: nil
                    ),
                    PersistedAgentState(
                        profile: "missing",
                        name: "legacy",
                        needsInput: false,
                        threadID: nil
                    )
                ]
            )]
        )]
        let manager = makeAgentManager()
        let model = WorktreeExplorerModel(
            discoverer: FakeWorktreeDiscoverer([current]),
            onActivate: { _, _ in },
            agentManager: manager,
            stateStore: store,
            watcherFactory: FakeRepositoryWatcherFactory().make,
            eventDelivery: { $0() }
        )

        model.restore(activateSelection: false)

        let worktreeNode = try XCTUnwrap(model.tree.roots.first?.children?.first)
        let agentNodes = try XCTUnwrap(worktreeNode.children)
        XCTAssertEqual(agentNodes.map(\.value.name), [
            "! reviewer [codex]", "legacy [missing]"
        ])
        XCTAssertTrue(model.tree.isExpanded(worktreeNode))
        guard case .agent(let reviewer) = agentNodes[0].value,
              case .agent(let legacy) = agentNodes[1].value else {
            return XCTFail("Expected agent leaf nodes")
        }
        XCTAssertNil(manager.session(for: reviewer.key), "Restore must not launch an agent")
        XCTAssertNil(model.profile(for: legacy), "Missing profiles use safe UI fallbacks")
        XCTAssertNil(worktreeContextMenuSnapshot(for: agentNodes[0], in: model))
        XCTAssertEqual(store.repositoryWrites.last?[0].worktrees[0].agents.count, 2)
    }

    @MainActor
    func testAgentSelectionActivatesAgentWithoutChangingWorktreeSelectionMeaning() throws {
        let current = repository(
            at: "/repos/project",
            worktrees: [worktree("main", at: "/repos/project", isMain: true)]
        )
        let manager = makeAgentManager()
        var worktreeActivations = 0
        var activatedAgent: AgentRecord?
        let model = WorktreeExplorerModel(
            discoverer: FakeWorktreeDiscoverer([current]),
            onActivate: { _, _ in worktreeActivations += 1 },
            agentManager: manager,
            onActivateAgent: { agent, repository, worktree in
                XCTAssertEqual(repository.id, current.id)
                XCTAssertEqual(worktree.id, current.worktrees[0].id)
                activatedAgent = agent
            },
            watcherFactory: FakeRepositoryWatcherFactory().make,
            eventDelivery: { $0() }
        )
        try model.addRepository(current.rootURL)
        manager.restore(
            [PersistedAgentState(
                profile: "codex",
                name: "reviewer",
                needsInput: false,
                threadID: nil
            )],
            repository: model.repositories[0],
            worktree: current.worktrees[0]
        )
        let worktreeNode = try XCTUnwrap(model.tree.roots[0].children?.first)
        let agentNode = try XCTUnwrap(worktreeNode.children?.first)

        model.activate(agentNode)

        XCTAssertEqual(activatedAgent?.name, "reviewer")
        XCTAssertEqual(model.selectedAgentID, activatedAgent?.key)
        XCTAssertEqual(model.selectedWorktreeID, current.worktrees[0].id)
        XCTAssertEqual(model.selectedNodeID, activatedAgent.map { .agent($0.key) })
        XCTAssertEqual(worktreeActivations, 0)

        model.activate(worktreeNode)
        XCTAssertNil(model.selectedAgentID)
        XCTAssertEqual(model.selectedNodeID, .worktree(current.worktrees[0].id))
        XCTAssertEqual(worktreeActivations, 1)
    }

    @MainActor
    func testCrossWorktreeAgentSelectionSurvivesWorkspaceSelectionSynchronization() throws {
        let main = worktree("main", at: "/repos/project", isMain: true)
        let topic = worktree("topic", at: "/worktrees/topic")
        let current = repository(at: "/repos/project", worktrees: [main, topic])
        let manager = makeAgentManager()
        let model = WorktreeExplorerModel(
            discoverer: FakeWorktreeDiscoverer([current]),
            onActivate: { _, _ in },
            agentManager: manager,
            onActivateAgent: { _, _, _ in },
            watcherFactory: FakeRepositoryWatcherFactory().make,
            eventDelivery: { $0() }
        )
        try model.addRepository(current.rootURL)
        manager.restore(
            [PersistedAgentState(
                profile: "codex",
                name: "reviewer",
                needsInput: false,
                threadID: nil
            )],
            repository: model.repositories[0],
            worktree: topic
        )
        let agentNode = try XCTUnwrap(
            model.tree.roots[0].children?.last?.children?.first
        )

        model.activate(agentNode)
        let selectedAgentID = try XCTUnwrap(model.selectedAgentID)
        XCTAssertEqual(model.selectedWorktreeID, topic.id)

        model.syncSelection(with: topic.url)
        XCTAssertEqual(model.selectedAgentID, selectedAgentID)
        XCTAssertEqual(model.selectedNodeID, .agent(selectedAgentID))

        model.syncSelection(with: main.url)
        XCTAssertNil(model.selectedAgentID)
        XCTAssertEqual(model.selectedNodeID, .worktree(main.id))
    }

    @MainActor
    func testAgentChangesRebuildPersistAndRevealWorktree() throws {
        let current = repository(
            at: "/repos/project",
            worktrees: [worktree("main", at: "/repos/project", isMain: true)]
        )
        let store = FakeWorkspaceStateStore()
        let manager = makeAgentManager()
        let model = WorktreeExplorerModel(
            discoverer: FakeWorktreeDiscoverer([current]),
            onActivate: { _, _ in },
            agentManager: manager,
            stateStore: store,
            watcherFactory: FakeRepositoryWatcherFactory().make,
            eventDelivery: { $0() }
        )
        try model.addRepository(current.rootURL)

        manager.restore(
            [PersistedAgentState(
                profile: "codex",
                name: "builder",
                needsInput: false,
                threadID: nil
            )],
            repository: model.repositories[0],
            worktree: current.worktrees[0]
        )

        var worktreeNode = try XCTUnwrap(model.tree.roots[0].children?.first)
        XCTAssertTrue(model.tree.isExpanded(worktreeNode))
        XCTAssertEqual(worktreeNode.children?.first?.value.name, "builder [codex]")
        XCTAssertEqual(store.repositoryWrites.last?[0].worktrees[0].agents.first?.name, "builder")

        manager.restore(
            [PersistedAgentState(
                profile: "codex",
                name: "builder",
                needsInput: true,
                threadID: "captured"
            )],
            repository: model.repositories[0],
            worktree: current.worktrees[0]
        )
        worktreeNode = try XCTUnwrap(model.tree.roots[0].children?.first)
        XCTAssertEqual(worktreeNode.children?.first?.value.name, "! builder [codex]")
        XCTAssertEqual(store.repositoryWrites.last?[0].worktrees[0].agents.first?.threadID, "captured")
    }

    @MainActor
    func testRefreshPreservesAgentsAndPurgesThoseForRemovedWorktrees() throws {
        let main = worktree("main", at: "/repos/project", isMain: true)
        let topic = worktree("topic", at: "/worktrees/topic")
        let initial = repository(at: "/repos/project", worktrees: [main, topic])
        let discoverer = FakeWorktreeDiscoverer([initial])
        let manager = makeAgentManager()
        let model = WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { _, _ in },
            agentManager: manager,
            watcherFactory: FakeRepositoryWatcherFactory().make,
            eventDelivery: { $0() }
        )
        try model.addRepository(initial.rootURL)
        manager.restore(
            [PersistedAgentState(
                profile: "codex",
                name: "topic-agent",
                needsInput: false,
                threadID: nil
            )],
            repository: model.repositories[0],
            worktree: topic
        )

        let renamed = worktree("renamed-topic", at: topic.url.path)
        discoverer.repositoriesByPath[initial.rootURL.path] = repository(
            at: initial.rootURL.path,
            worktrees: [main, renamed]
        )
        model.refreshRepository(id: initial.id)
        XCTAssertEqual(
            model.tree.roots[0].children?.last?.children?.first?.value.name,
            "topic-agent [codex]"
        )
        XCTAssertEqual(manager.records(for: renamed.url).count, 1)

        discoverer.repositoriesByPath[initial.rootURL.path] = repository(
            at: initial.rootURL.path,
            worktrees: [main]
        )
        model.refreshRepository(id: initial.id)
        XCTAssertTrue(manager.records(for: topic.url).isEmpty)
        XCTAssertEqual(model.tree.roots[0].children?.count, 1)
    }

    @MainActor
    func testWorktreeExpansionWithAgentsRoundTripsThroughRepositoryState() throws {
        let current = repository(
            at: "/repos/project",
            worktrees: [worktree("main", at: "/repos/project", isMain: true)]
        )
        let store = FakeWorkspaceStateStore()
        let manager = makeAgentManager()
        let model = WorktreeExplorerModel(
            discoverer: FakeWorktreeDiscoverer([current]),
            onActivate: { _, _ in },
            agentManager: manager,
            stateStore: store,
            watcherFactory: FakeRepositoryWatcherFactory().make,
            eventDelivery: { $0() }
        )
        try model.addRepository(current.rootURL)
        manager.restore(
            [PersistedAgentState(
                profile: "codex",
                name: "builder",
                needsInput: false,
                threadID: nil
            )],
            repository: model.repositories[0],
            worktree: current.worktrees[0]
        )
        let worktreeNode = try XCTUnwrap(model.tree.roots[0].children?.first)
        XCTAssertTrue(model.tree.isExpanded(worktreeNode))
        XCTAssertEqual(store.repositoryWrites.last?[0].worktrees[0].isExpanded, true)

        let restoredStore = FakeWorkspaceStateStore()
        restoredStore.loadedRepositories = try XCTUnwrap(store.repositoryWrites.last)
        let restoredManager = makeAgentManager()
        let restored = WorktreeExplorerModel(
            discoverer: FakeWorktreeDiscoverer([current]),
            onActivate: { _, _ in },
            agentManager: restoredManager,
            stateStore: restoredStore,
            watcherFactory: FakeRepositoryWatcherFactory().make,
            eventDelivery: { $0() }
        )
        restored.restore(activateSelection: false)

        let restoredWorktree = try XCTUnwrap(restored.tree.roots[0].children?.first)
        XCTAssertTrue(restored.tree.isExpanded(restoredWorktree))
        XCTAssertEqual(restoredWorktree.children?.first?.value.name, "builder [codex]")
    }

    @MainActor
    func testAllocatesStableCanonicalNamesForSameNamedRepositories() throws {
        let first = repository(at: "/repos/one/DevHQ", worktrees: [])
        let second = repository(at: "/repos/two/devhq", worktrees: [])
        let third = repository(at: "/repos/three/DEVHQ", worktrees: [])
        let discoverer = FakeWorktreeDiscoverer([first, second, third])
        let watcherFactory = FakeRepositoryWatcherFactory()
        let model = WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { _ in },
            watcherFactory: watcherFactory.make,
            eventDelivery: { $0() }
        )

        try model.addRepository(first.rootURL)
        try model.addRepository(second.rootURL)
        try model.addRepository(third.rootURL)
        XCTAssertEqual(model.repositories.map(\.canonicalName), [
            "DevHQ", "devhq-2", "DEVHQ-3"
        ])

        discoverer.repositoriesByPath[second.rootURL.standardizedFileURL.path] = repository(
            at: "/repos/two/devhq",
            worktrees: [worktree("updated", at: "/worktrees/updated")]
        )
        model.refreshRepository(id: second.id)
        XCTAssertEqual(model.repositories[1].canonicalName, "devhq-2")
        XCTAssertEqual(model.tree.roots[1].value.name, "devhq-2")
    }

    @MainActor
    func testRefreshReportsSelectedBranchIdentityChangeWithoutReactivation() throws {
        let original = worktree("feature/old", at: "/worktrees/feature")
        let initial = repository(
            at: "/repos/project",
            worktrees: [original]
        )
        let discoverer = FakeWorktreeDiscoverer([initial])
        let watcherFactory = FakeRepositoryWatcherFactory()
        var activationCount = 0
        var identityChanges: [(GitRepositoryInfo, GitWorktreeInfo)] = []
        let model = WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { _, _ in activationCount += 1 },
            onSelectionIdentityChange: { identityChanges.append(($0, $1)) },
            watcherFactory: watcherFactory.make,
            eventDelivery: { $0() }
        )
        try model.addRepository(initial.rootURL)
        model.activate(try XCTUnwrap(model.tree.roots[0].children?.first))

        discoverer.repositoriesByPath[initial.rootURL.standardizedFileURL.path] = repository(
            at: "/repos/project",
            worktrees: [worktree("feature/new", at: "/worktrees/feature")]
        )
        try XCTUnwrap(watcherFactory.watcher(for: initial.gitDirectoryURL)).signalChange()

        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(identityChanges.count, 1)
        XCTAssertEqual(identityChanges.first?.0.canonicalName, "project")
        XCTAssertEqual(identityChanges.first?.1.name, "feature/new")
        XCTAssertEqual(model.selectedWorktreeID, original.id)
    }

    @MainActor
    func testWatcherFailureRestoresDiscoveredRepositoryAndLaterRefreshInstallsWatcher() throws {
        let savedRoot = URL(fileURLWithPath: "/offline/devhq", isDirectory: true)
        let savedWorktree = PersistedWorktreeState(
            branchName: "feature/saved",
            path: "/offline-worktrees/saved",
            isMain: false,
            isExpanded: false,
            isSelected: true
        )
        let saved = PersistedRepositoryState(
            canonicalName: "devhq",
            rootPath: savedRoot.path,
            gitDirectoryPath: savedRoot.appendingPathComponent(".git").path,
            isExpanded: false,
            worktrees: [savedWorktree]
        )
        let recovered = repository(
            at: savedRoot.path,
            worktrees: [worktree("feature/recovered", at: savedWorktree.path)]
        )
        let discoverer = FakeWorktreeDiscoverer([recovered])
        let store = FakeWorkspaceStateStore()
        store.loadedRepositories = [saved]
        let watcherFactory = FakeRepositoryWatcherFactory()
        var watcherShouldFail = true
        let factory: RepositoryWatcherFactory = { url, onChange in
            if watcherShouldFail { throw CocoaError(.fileReadNoPermission) }
            return watcherFactory.make(url: url, onChange: onChange)
        }
        var activations: [(GitRepositoryInfo, GitWorktreeInfo)] = []
        let model = WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { activations.append(($0, $1)) },
            stateStore: store,
            watcherFactory: factory,
            eventDelivery: { $0() }
        )

        let selection = model.restore()

        XCTAssertEqual(model.repositories.map(\.canonicalName), ["devhq"])
        XCTAssertEqual(model.repositories[0].worktrees.map(\.name), ["feature/recovered"])
        XCTAssertEqual(model.selectedWorktreeID, savedWorktree.path)
        XCTAssertFalse(model.tree.isExpanded(model.tree.roots[0]))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(selection?.worktree.name, "feature/recovered")
        XCTAssertEqual(activations.count, 1)
        XCTAssertEqual(activations.first?.0.canonicalName, "devhq")
        XCTAssertEqual(activations.first?.1.name, "feature/recovered")
        XCTAssertEqual(store.repositoryWrites.last?[0].worktrees.map(\.branchName), [
            "feature/recovered"
        ])
        XCTAssertNil(watcherFactory.watcher(for: recovered.gitDirectoryURL))

        watcherShouldFail = false
        model.refreshRepository(id: recovered.id)

        XCTAssertNotNil(watcherFactory.watcher(for: recovered.gitDirectoryURL))
        XCTAssertEqual(model.repositories[0].worktrees.map(\.name), ["feature/recovered"])
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testDiscoveryFailureKeepsPersistedRepositoryWithoutRewritingState() {
        let saved = PersistedRepositoryState(
            canonicalName: "offline",
            rootPath: "/missing/offline",
            gitDirectoryPath: "/missing/offline/.git",
            isExpanded: true,
            worktrees: [
                PersistedWorktreeState(
                    branchName: "main",
                    path: "/missing/offline",
                    isMain: true,
                    isExpanded: false,
                    isSelected: false
                )
            ]
        )
        let store = FakeWorkspaceStateStore()
        store.loadedRepositories = [saved]
        let watcherFactory = FakeRepositoryWatcherFactory()
        let model = WorktreeExplorerModel(
            discoverer: FakeWorktreeDiscoverer([]),
            onActivate: { _, _ in },
            stateStore: store,
            watcherFactory: watcherFactory.make,
            eventDelivery: { $0() }
        )

        XCTAssertNil(model.restore())
        XCTAssertEqual(model.repositories.map(\.canonicalName), ["offline"])
        XCTAssertEqual(model.repositories[0].worktrees.map(\.name), ["main"])
        XCTAssertTrue(model.tree.isExpanded(model.tree.roots[0]))
        XCTAssertTrue(store.repositoryWrites.isEmpty)
        XCTAssertTrue(watcherFactory.watchersByPath.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testPersistsRepositoryOrderDiscoveryAndSelectionChanges() throws {
        let first = repository(
            at: "/repos/first",
            worktrees: [worktree("main", at: "/repos/first", isMain: true)]
        )
        let second = repository(
            at: "/repos/second",
            worktrees: [worktree("topic/branch", at: "/worktrees/topic")]
        )
        let store = FakeWorkspaceStateStore()
        let discoverer = FakeWorktreeDiscoverer([first, second])
        let model = WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { _, _ in },
            stateStore: store,
            watcherFactory: FakeRepositoryWatcherFactory().make,
            eventDelivery: { $0() }
        )

        try model.addRepository(first.rootURL)
        try model.addRepository(second.rootURL)
        XCTAssertEqual(store.repositoryWrites.last?.map(\.canonicalName), ["first", "second"])
        XCTAssertEqual(store.repositoryWrites.last?.map(\.rootPath), [
            first.rootURL.path, second.rootURL.path
        ])
        XCTAssertEqual(store.repositoryWrites.last?[1].worktrees, [
            PersistedWorktreeState(
                branchName: "topic/branch",
                path: "/worktrees/topic",
                isMain: false,
                isExpanded: false,
                isSelected: false
            )
        ])

        model.activate(try XCTUnwrap(model.tree.roots[1].children?.first))
        XCTAssertEqual(store.repositoryWrites.last?[1].worktrees.first?.isSelected, true)

        model.syncSelection(with: nil)
        XCTAssertEqual(store.repositoryWrites.last?[1].worktrees.first?.isSelected, false)

        model.removeRepository(id: first.id)
        XCTAssertEqual(store.repositoryWrites.last?.map(\.canonicalName), ["second"])
    }

    @MainActor
    func testRestoreRediscoversWorktreesPreservesExplorerStateAndActivatesSelectionOnce() throws {
        let firstCurrent = repository(
            at: "/repos/first",
            worktrees: [
                worktree("main", at: "/repos/first", isMain: true),
                worktree("renamed-branch", at: "/worktrees/selected")
            ]
        )
        let secondCurrent = repository(
            at: "/repos/second",
            worktrees: [worktree("main", at: "/repos/second", isMain: true)]
        )
        let store = FakeWorkspaceStateStore()
        store.loadedRepositories = [
            persistedRepository(
                canonicalName: "second-custom",
                repository: secondCurrent,
                isExpanded: true
            ),
            PersistedRepositoryState(
                canonicalName: "first-custom",
                rootPath: firstCurrent.rootURL.path,
                gitDirectoryPath: firstCurrent.gitDirectoryURL.path,
                isExpanded: false,
                worktrees: [
                    PersistedWorktreeState(
                        branchName: "old-branch-name",
                        path: "/worktrees/selected",
                        isMain: false,
                        isExpanded: false,
                        isSelected: true
                    )
                ]
            )
        ]
        let watcherFactory = FakeRepositoryWatcherFactory()
        var activations: [(GitRepositoryInfo, GitWorktreeInfo)] = []
        let model = WorktreeExplorerModel(
            discoverer: FakeWorktreeDiscoverer([firstCurrent, secondCurrent]),
            onActivate: { activations.append(($0, $1)) },
            stateStore: store,
            watcherFactory: watcherFactory.make,
            eventDelivery: { $0() }
        )

        let selection = model.restore()

        XCTAssertEqual(model.repositories.map(\.canonicalName), [
            "second-custom", "first-custom"
        ])
        XCTAssertTrue(model.tree.isExpanded(model.tree.roots[0]))
        XCTAssertFalse(model.tree.isExpanded(model.tree.roots[1]))
        XCTAssertEqual(selection?.worktree.name, "renamed-branch")
        XCTAssertEqual(model.selectedWorktreeID, "/worktrees/selected")
        XCTAssertEqual(activations.count, 1)
        XCTAssertEqual(activations.first?.0.canonicalName, "first-custom")
        XCTAssertEqual(activations.first?.1.url.path, "/worktrees/selected")
        XCTAssertNotNil(watcherFactory.watcher(for: firstCurrent.gitDirectoryURL))
        XCTAssertNotNil(watcherFactory.watcher(for: secondCurrent.gitDirectoryURL))
        XCTAssertEqual(
            store.repositoryWrites.last?[1].worktrees.map(\.branchName),
            ["main", "renamed-branch"]
        )
    }

    @MainActor
    func testRestoreCanDeferSelectedWorktreeActivation() {
        let current = repository(
            at: "/repos/project",
            worktrees: [worktree("main", at: "/repos/project", isMain: true)]
        )
        let store = FakeWorkspaceStateStore()
        store.loadedRepositories = [persistedRepository(
            canonicalName: "project",
            repository: current,
            isExpanded: true,
            selectedPath: current.rootURL.path
        )]
        var activationCount = 0
        let model = WorktreeExplorerModel(
            discoverer: FakeWorktreeDiscoverer([current]),
            onActivate: { _, _ in activationCount += 1 },
            stateStore: store,
            watcherFactory: FakeRepositoryWatcherFactory().make,
            eventDelivery: { $0() }
        )

        let selection = model.restore(activateSelection: false)

        XCTAssertEqual(selection?.worktree.id, current.worktrees[0].id)
        XCTAssertEqual(model.selectedWorktreeID, current.worktrees[0].id)
        XCTAssertEqual(activationCount, 0)
    }

    @MainActor
    func testWatcherRefreshPersistsAddedAndRemovedWorktreesAndClearsSelection() throws {
        let main = worktree("main", at: "/repos/project", isMain: true)
        let topic = worktree("topic", at: "/worktrees/topic")
        let initial = repository(at: "/repos/project", worktrees: [main, topic])
        let discoverer = FakeWorktreeDiscoverer([initial])
        let watcherFactory = FakeRepositoryWatcherFactory()
        let store = FakeWorkspaceStateStore()
        let model = WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { _, _ in },
            stateStore: store,
            watcherFactory: watcherFactory.make,
            eventDelivery: { $0() }
        )
        try model.addRepository(initial.rootURL)
        model.activate(try XCTUnwrap(model.tree.roots[0].children?.last))
        let watcher = try XCTUnwrap(watcherFactory.watcher(for: initial.gitDirectoryURL))

        let added = worktree("added", at: "/worktrees/added")
        discoverer.repositoriesByPath[initial.rootURL.standardizedFileURL.path] = repository(
            at: "/repos/project",
            worktrees: [main, topic, added]
        )
        watcher.signalChange()
        XCTAssertEqual(store.repositoryWrites.last?[0].worktrees.map(\.branchName), [
            "main", "topic", "added"
        ])

        discoverer.repositoriesByPath[initial.rootURL.standardizedFileURL.path] = repository(
            at: "/repos/project",
            worktrees: [main, added]
        )
        watcher.signalChange()
        XCTAssertNil(model.selectedWorktreeID)
        XCTAssertFalse(store.repositoryWrites.last?[0].worktrees.contains(where: \.isSelected) ?? true)
    }

    @MainActor
    func testTogglePersistsRepositoryExpansionButNotLeafToggles() throws {
        let current = repository(
            at: "/repos/project",
            worktrees: [worktree("main", at: "/repos/project", isMain: true)]
        )
        let store = FakeWorkspaceStateStore()
        let model = WorktreeExplorerModel(
            discoverer: FakeWorktreeDiscoverer([current]),
            onActivate: { _, _ in },
            stateStore: store,
            watcherFactory: FakeRepositoryWatcherFactory().make,
            eventDelivery: { $0() }
        )
        try model.addRepository(current.rootURL)
        XCTAssertEqual(store.repositoryWrites.count, 1)

        model.toggle(model.tree.roots[0])
        XCTAssertEqual(store.repositoryWrites.count, 2)
        XCTAssertEqual(store.repositoryWrites.last?[0].isExpanded, false)

        model.toggle(try XCTUnwrap(model.tree.roots[0].children?.first))
        XCTAssertEqual(store.repositoryWrites.count, 2)
    }

    @MainActor
    func testBuildsOneRepositoryBranchPerAddedRepository() throws {
        let first = repository(
            at: "/repos/first",
            worktrees: [
                worktree("main", at: "/repos/first", isMain: true),
                worktree("feature", at: "/worktrees/first-feature")
            ]
        )
        let second = repository(
            at: "/repos/second",
            worktrees: [worktree("main", at: "/repos/second", isMain: true)]
        )
        let discoverer = FakeWorktreeDiscoverer([first, second])
        let watcherFactory = FakeRepositoryWatcherFactory()
        var activated: GitWorktreeInfo?
        let model = WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { activated = $0 },
            watcherFactory: watcherFactory.make,
            eventDelivery: { $0() }
        )

        try model.addRepository(first.rootURL)
        try model.addRepository(second.rootURL)

        XCTAssertEqual(model.repositories.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.tree.roots.count, 2)
        XCTAssertEqual(model.tree.roots[0].children?.count, 2)
        XCTAssertEqual(model.tree.roots[1].children?.count, 1)
        XCTAssertTrue(model.tree.isExpanded(model.tree.roots[0]))

        let featureNode = try XCTUnwrap(model.tree.roots[0].children?.last)
        model.activate(featureNode)
        XCTAssertEqual(model.selectedWorktreeID, first.worktrees.last?.id)
        XCTAssertEqual(activated?.id, first.worktrees.last?.id)

        XCTAssertThrowsError(try model.addRepository(first.rootURL)) { error in
            XCTAssertEqual(
                error as? WorktreeExplorerModel.ExplorerError,
                .duplicateRepository(first.name)
            )
        }
        XCTAssertEqual(model.tree.roots.count, 2)
    }

    @MainActor
    func testWatcherRefreshAddsAndRemovesWorktreesAndMaintainsSelection() throws {
        let main = worktree("main", at: "/repos/project", isMain: true)
        let feature = worktree("feature", at: "/worktrees/project-feature")
        let initial = repository(at: "/repos/project", worktrees: [main, feature])
        let discoverer = FakeWorktreeDiscoverer([initial])
        let watcherFactory = FakeRepositoryWatcherFactory()
        var activations = 0
        let model = WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { _ in activations += 1 },
            watcherFactory: watcherFactory.make,
            eventDelivery: { $0() }
        )
        try model.addRepository(initial.rootURL)
        model.activate(try XCTUnwrap(model.tree.roots[0].children?.last))
        model.tree.toggle(model.tree.roots[0])
        XCTAssertFalse(model.tree.isExpanded(model.tree.roots[0]))

        let added = worktree("review", at: "/worktrees/project-review")
        discoverer.repositoriesByPath[initial.rootURL.standardizedFileURL.path] = repository(
            at: "/repos/project",
            worktrees: [main, feature, added]
        )
        let watcher = try XCTUnwrap(watcherFactory.watcher(for: initial.gitDirectoryURL))
        watcher.signalChange()

        XCTAssertEqual(model.tree.roots[0].children?.count, 3)
        XCTAssertEqual(model.selectedWorktreeID, feature.id)
        XCTAssertFalse(model.tree.isExpanded(model.tree.roots[0]))
        XCTAssertEqual(activations, 1, "Refresh must not activate a worktree")

        discoverer.repositoriesByPath[initial.rootURL.standardizedFileURL.path] = repository(
            at: "/repos/project",
            worktrees: [main, added]
        )
        watcher.signalChange()

        XCTAssertEqual(model.tree.roots[0].children?.count, 2)
        XCTAssertNil(model.selectedWorktreeID)
        XCTAssertEqual(activations, 1)
    }

    @MainActor
    func testSynchronizesSelectionFromWorkspaceURL() throws {
        let feature = worktree("feature", at: "/worktrees/project-feature")
        let repository = repository(
            at: "/repos/project",
            worktrees: [worktree("main", at: "/repos/project", isMain: true), feature]
        )
        let discoverer = FakeWorktreeDiscoverer([repository])
        let watcherFactory = FakeRepositoryWatcherFactory()
        let model = WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { _ in },
            watcherFactory: watcherFactory.make,
            eventDelivery: { $0() }
        )
        try model.addRepository(repository.rootURL)

        model.syncSelection(with: feature.url)
        XCTAssertEqual(model.selectedNodeID, .worktree(feature.id))

        model.syncSelection(with: URL(fileURLWithPath: "/an/untracked/folder"))
        XCTAssertNil(model.selectedNodeID)

        model.syncSelection(with: nil)
        XCTAssertNil(model.selectedNodeID)
    }

    func testRepositoryWatcherObservesLinkedWorktreeMetadataChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let worktrees = directory.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let changed = expectation(description: "Git worktree metadata changed")
        changed.assertForOverFulfill = false
        let watcher = try RepositoryWatcher(
            gitDirectoryURL: directory,
            debounceInterval: .milliseconds(10)
        ) {
            changed.fulfill()
        }
        defer { watcher.cancel() }

        try FileManager.default.createDirectory(
            at: worktrees.appendingPathComponent("new-worktree", isDirectory: true),
            withIntermediateDirectories: false
        )

        wait(for: [changed], timeout: 2)
    }

    func testRepositoryWatcherObservesWorktreesDirectoryRemoval() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let worktrees = directory.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let changed = expectation(description: "Git worktrees directory removed")
        changed.assertForOverFulfill = false
        let watcher = try RepositoryWatcher(
            gitDirectoryURL: directory,
            debounceInterval: .milliseconds(10)
        ) {
            changed.fulfill()
        }
        defer { watcher.cancel() }

        try FileManager.default.removeItem(at: worktrees)

        wait(for: [changed], timeout: 2)
    }

    func testRepositoryWatcherCancellationSuppressesPendingEvent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let changed = expectation(description: "Cancelled watcher callback")
        changed.isInverted = true
        let watcher = try RepositoryWatcher(
            gitDirectoryURL: directory,
            debounceInterval: .milliseconds(20)
        ) {
            changed.fulfill()
        }

        watcher.scheduleChange()
        watcher.cancel()

        wait(for: [changed], timeout: 0.15)
    }

    @MainActor
    private func makeAgentManager() -> AgentManager {
        AgentManager(
            workspace: WorkspaceModel(),
            profiles: AgentProfileRegistry(),
            patternMatcher: ExplorerAgentPatternMatcher()
        )
    }

    private func worktree(
        _ name: String,
        at path: String,
        isMain: Bool = false
    ) -> GitWorktreeInfo {
        GitWorktreeInfo(
            name: name,
            url: URL(fileURLWithPath: path, isDirectory: true),
            isMain: isMain
        )
    }

    private func repository(
        at path: String,
        worktrees: [GitWorktreeInfo]
    ) -> GitRepositoryInfo {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        return GitRepositoryInfo(
            rootURL: root,
            name: root.lastPathComponent,
            gitDirectoryURL: root.appendingPathComponent(".git", isDirectory: true),
            worktrees: worktrees
        )
    }

    private func persistedRepository(
        canonicalName: String,
        repository: GitRepositoryInfo,
        isExpanded: Bool,
        selectedPath: String? = nil
    ) -> PersistedRepositoryState {
        PersistedRepositoryState(
            canonicalName: canonicalName,
            rootPath: repository.rootURL.path,
            gitDirectoryPath: repository.gitDirectoryURL.path,
            isExpanded: isExpanded,
            worktrees: repository.worktrees.map { worktree in
                PersistedWorktreeState(
                    branchName: worktree.name,
                    path: worktree.url.path,
                    isMain: worktree.isMain,
                    isExpanded: false,
                    isSelected: worktree.url.path == selectedPath
                )
            }
        )
    }
}
