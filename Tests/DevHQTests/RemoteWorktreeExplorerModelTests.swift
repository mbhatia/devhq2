import Foundation
import XCTest
@testable import DevHQ

private enum RemoteExplorerTestError: LocalizedError {
    case failed

    var errorDescription: String? { "sync failed" }
}

private final class RemoteExplorerServiceStub: SSHRemoteRepositoryServicing, @unchecked Sendable {
    let mirrorRoot: URL
    var results: [Result<SSHRemoteRepositorySnapshot, Error>]
    private(set) var synchronizedSources: [SSHRemoteRepositorySource] = []
    private(set) var synchronizationContexts: [SSHRemoteSynchronizationContext] = []

    init(
        mirrorRoot: URL = URL(fileURLWithPath: "/cache/devhq/remote-mirrors"),
        results: [Result<SSHRemoteRepositorySnapshot, Error>] = []
    ) {
        self.mirrorRoot = mirrorRoot
        self.results = results
    }

    func parseSource(_ specification: String) throws -> SSHRemoteRepositorySource {
        try SSHRemoteRepositorySource(specification: specification)
    }

    func mirrorPath(for source: SSHRemoteRepositorySource) -> URL {
        mirrorRoot
            .appendingPathComponent(source.server, isDirectory: true)
            .appendingPathComponent(source.repositoryName, isDirectory: true)
    }

    func synchronize(
        _ source: SSHRemoteRepositorySource
    ) async throws -> SSHRemoteRepositorySnapshot {
        try await synchronize(source, context: SSHRemoteSynchronizationContext())
    }

    func synchronize(
        _ source: SSHRemoteRepositorySource,
        context: SSHRemoteSynchronizationContext
    ) async throws -> SSHRemoteRepositorySnapshot {
        synchronizedSources.append(source)
        synchronizationContexts.append(context)
        return try results.removeFirst().get()
    }
}

private final class RemoteExplorerStateStore: WorkspaceStatePersisting {
    var loadedRepositories: [PersistedRepositoryState] = []
    private(set) var writes: [[PersistedRepositoryState]] = []

    func loadRepositories() throws -> [PersistedRepositoryState] { loadedRepositories }
    func saveRepositories(_ repositories: [PersistedRepositoryState]) throws {
        writes.append(repositories)
    }
    func loadWorkspaceState(
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws -> PersistedWorkspaceState? { nil }
    func saveWorkspaceState(
        _ state: PersistedWorkspaceState,
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws {}
}

private final class RemoteExplorerDiscoverer: GitWorktreeDiscovering {
    var repositories: [String: GitRepositoryInfo] = [:]
    private(set) var calls: [URL] = []

    func discover(at url: URL) throws -> GitRepositoryInfo {
        calls.append(url)
        guard let repository = repositories[url.standardizedFileURL.path] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return repository
    }
}

final class RemoteWorktreeExplorerModelTests: XCTestCase {
    @MainActor
    func testAddRemotePersistsRegistrationThenPublishesMirroredWorktrees() async throws {
        let source = try SSHRemoteRepositorySource(server: "build", remotePath: "/srv/devhq")
        let snapshot = remoteSnapshot(source: source, branch: "main")
        let service = RemoteExplorerServiceStub(results: [.success(snapshot)])
        let store = RemoteExplorerStateStore()
        var activation: (GitRepositoryInfo, GitWorktreeInfo)?
        let model = WorktreeExplorerModel(
            discoverer: RemoteExplorerDiscoverer(),
            remoteService: service,
            onActivate: { activation = ($0, $1) },
            stateStore: store,
            watcherFactory: { _, _ in
                XCTFail("Managed remote mirrors must not install local repository watchers")
                throw CocoaError(.featureUnsupported)
            }
        )

        try await model.addRemoteRepository(source.specification)

        XCTAssertEqual(store.writes.first?.first?.server, "build")
        XCTAssertEqual(store.writes.first?.first?.remotePath, "/srv/devhq")
        XCTAssertEqual(store.writes.first?.first?.worktrees, [])
        let repository = try XCTUnwrap(model.repositories.first)
        let worktree = try XCTUnwrap(repository.worktrees.first)
        XCTAssertEqual(worktree.remotePath, "/srv/devhq")
        XCTAssertEqual(worktree.displayName, "[build] main")
        XCTAssertNil(repository.lastSyncError)
        XCTAssertEqual(
            service.synchronizationContexts.map(\.allowExistingCloneReferenceReuse),
            [true]
        )

        model.activate(try XCTUnwrap(model.tree.roots.first?.children?.first))
        XCTAssertEqual(activation?.0.remoteSource, source)
        XCTAssertEqual(activation?.1.url, snapshot.worktrees[0].localURL.standardizedFileURL)
    }

    @MainActor
    func testFailedAddRetainsRegistrationAndPersistsError() async throws {
        let source = try SSHRemoteRepositorySource(server: "build", remotePath: "/srv/devhq")
        let service = RemoteExplorerServiceStub(results: [
            .failure(RemoteExplorerTestError.failed),
            .success(remoteSnapshot(source: source, branch: "main"))
        ])
        let store = RemoteExplorerStateStore()
        let model = WorktreeExplorerModel(
            discoverer: RemoteExplorerDiscoverer(),
            remoteService: service,
            onActivate: { _, _ in },
            stateStore: store
        )

        do {
            try await model.addRemoteRepository("build:/srv/devhq")
            XCTFail("Expected synchronization failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "sync failed")
        }

        XCTAssertEqual(model.repositories.count, 1)
        XCTAssertEqual(model.repositories[0].worktrees, [])
        XCTAssertEqual(model.repositories[0].lastSyncError, "sync failed")
        XCTAssertEqual(store.writes.last?.first?.lastSyncError, "sync failed")
        XCTAssertEqual(
            service.synchronizationContexts.map(\.allowExistingCloneReferenceReuse),
            [true]
        )

        await model.synchronizeRemoteRepositories()

        XCTAssertEqual(
            service.synchronizationContexts.map(\.allowExistingCloneReferenceReuse),
            [true, true],
            "A failed first synchronization still has only placeholder metadata."
        )
        XCTAssertEqual(model.repositories[0].worktrees.map(\.name), ["main"])
    }

    @MainActor
    func testFailedRefreshPreservesLastSuccessfulMetadata() async throws {
        let source = try SSHRemoteRepositorySource(server: "build", remotePath: "/srv/devhq")
        let snapshot = remoteSnapshot(source: source, branch: "develop")
        let service = RemoteExplorerServiceStub(results: [
            .success(snapshot),
            .failure(RemoteExplorerTestError.failed)
        ])
        let model = WorktreeExplorerModel(
            discoverer: RemoteExplorerDiscoverer(),
            remoteService: service,
            onActivate: { _, _ in }
        )

        try await model.addRemoteRepository(source.specification)
        await model.synchronizeRemoteRepositories()

        XCTAssertEqual(model.repositories[0].worktrees.map(\.name), ["develop"])
        XCTAssertEqual(model.repositories[0].lastSyncError, "sync failed")
        XCTAssertEqual(
            service.synchronizationContexts.map(\.allowExistingCloneReferenceReuse),
            [true, false],
            "A repository with successful worktree metadata must use normal fetch semantics."
        )
    }

    @MainActor
    func testRefreshAppliesPersistsAndReportsCleanupWarnings() async throws {
        let source = try SSHRemoteRepositorySource(server: "build", remotePath: "/srv/devhq")
        let initial = remoteSnapshot(source: source, branch: "main")
        let refreshed = SSHRemoteRepositorySnapshot(
            source: source,
            rootURL: initial.rootURL,
            gitDirectoryURL: initial.gitDirectoryURL,
            worktrees: [SSHRemoteWorktreeSnapshot(
                name: "develop",
                localURL: initial.rootURL,
                remotePath: source.remotePath,
                isMain: true,
                head: "def456"
            )],
            cleanupWarnings: ["Could not prune a protected stale checkout."]
        )
        let service = RemoteExplorerServiceStub(results: [
            .success(initial),
            .success(refreshed)
        ])
        let store = RemoteExplorerStateStore()
        let model = WorktreeExplorerModel(
            discoverer: RemoteExplorerDiscoverer(),
            remoteService: service,
            onActivate: { _, _ in },
            stateStore: store
        )

        try await model.addRemoteRepository(source.specification)
        await model.synchronizeRemoteRepositories()

        XCTAssertEqual(model.repositories[0].worktrees.map(\.name), ["develop"])
        XCTAssertEqual(
            model.repositories[0].lastSyncError,
            "Could not prune a protected stale checkout."
        )
        XCTAssertEqual(
            store.writes.last?.first?.lastSyncError,
            "Could not prune a protected stale checkout."
        )
        XCTAssertEqual(
            model.errorMessage,
            "Remote synchronization completed with cleanup warnings: "
                + "build:/srv/devhq: Could not prune a protected stale checkout."
        )
    }

    @MainActor
    func testSuccessfulRefreshReportsRemovedSelectedRemoteWorktree() async throws {
        let source = try SSHRemoteRepositorySource(server: "build", remotePath: "/srv/devhq")
        let initial = remoteSnapshot(source: source, branch: "main")
        let empty = SSHRemoteRepositorySnapshot(
            source: source,
            rootURL: initial.rootURL,
            gitDirectoryURL: initial.gitDirectoryURL,
            worktrees: []
        )
        let service = RemoteExplorerServiceStub(results: [
            .success(initial),
            .success(empty)
        ])
        var removed: (GitRepositoryInfo, GitWorktreeInfo)?
        let model = WorktreeExplorerModel(
            discoverer: RemoteExplorerDiscoverer(),
            remoteService: service,
            onActivate: { _, _ in },
            onWorktreeRemoved: { removed = ($0, $1) }
        )

        try await model.addRemoteRepository(source.specification)
        model.activate(try XCTUnwrap(model.tree.roots.first?.children?.first))
        await model.synchronizeRemoteRepositories()

        XCTAssertEqual(removed?.0.remoteSource, source)
        XCTAssertEqual(removed?.1.name, "main")
        XCTAssertEqual(removed?.1.remotePath, "/srv/devhq")
        XCTAssertNil(model.selectedWorktreeID)
        XCTAssertEqual(model.repositories[0].worktrees, [])
    }

    @MainActor
    func testRefreshDefersBeforeTouchingRepositoryWithUnsavedWorktree() async throws {
        let source = try SSHRemoteRepositorySource(server: "build", remotePath: "/srv/devhq")
        let initial = remoteSnapshot(source: source, branch: "main")
        let removed = SSHRemoteRepositorySnapshot(
            source: source,
            rootURL: initial.rootURL,
            gitDirectoryURL: initial.gitDirectoryURL,
            worktrees: []
        )
        let service = RemoteExplorerServiceStub(results: [
            .success(initial),
            .success(removed)
        ])
        var allowsSynchronization = true
        var removalCount = 0
        let model = WorktreeExplorerModel(
            discoverer: RemoteExplorerDiscoverer(),
            remoteService: service,
            onActivate: { _, _ in },
            onWorktreeRemoved: { _, _ in removalCount += 1 },
            shouldSynchronizeRemoteRepository: { _ in allowsSynchronization }
        )

        try await model.addRemoteRepository(source.specification)
        model.activate(try XCTUnwrap(model.tree.roots.first?.children?.first))
        allowsSynchronization = false
        await model.synchronizeRemoteRepositories()

        XCTAssertEqual(service.synchronizedSources, [source])
        XCTAssertEqual(model.repositories[0].worktrees.map(\.name), ["main"])
        XCTAssertEqual(model.selectedWorktreeID, initial.worktrees[0].localURL.standardizedFileURL.path)
        XCTAssertEqual(removalCount, 0)
        XCTAssertEqual(
            model.errorMessage,
            "Skipped remote synchronization for build:/srv/devhq because of unsaved editor changes."
        )
    }

    @MainActor
    func testRestoreUsesPersistedRemoteMetadataWithoutDiscoveryOrSynchronization() throws {
        let discoverer = RemoteExplorerDiscoverer()
        let service = RemoteExplorerServiceStub()
        let store = RemoteExplorerStateStore()
        store.loadedRepositories = [PersistedRepositoryState(
            canonicalName: "devhq",
            rootPath: "/cache/build/devhq",
            gitDirectoryPath: "/cache/build/devhq/.git",
            isExpanded: true,
            worktrees: [PersistedWorktreeState(
                branchName: "main",
                path: "/cache/build/devhq",
                isMain: true,
                isExpanded: false,
                isSelected: false,
                remotePath: "/srv/devhq"
            )],
            server: "build",
            remotePath: "/srv/devhq",
            lastSyncError: "offline"
        )]
        var watcherCount = 0
        let model = WorktreeExplorerModel(
            discoverer: discoverer,
            remoteService: service,
            onActivate: { _, _ in },
            stateStore: store,
            watcherFactory: { _, _ in
                watcherCount += 1
                throw CocoaError(.featureUnsupported)
            }
        )

        model.restore(activateSelection: false)

        XCTAssertEqual(discoverer.calls, [])
        XCTAssertEqual(service.synchronizedSources, [])
        XCTAssertEqual(watcherCount, 0)
        XCTAssertEqual(model.repositories[0].worktrees[0].displayName, "[build] main")
        XCTAssertEqual(model.repositories[0].lastSyncError, "offline")
    }

    @MainActor
    func testRestoredIncompleteRemoteAllowsExistingCloneReferenceReuse() async throws {
        let source = try SSHRemoteRepositorySource(server: "build", remotePath: "/srv/devhq")
        let service = RemoteExplorerServiceStub(results: [
            .success(remoteSnapshot(source: source, branch: "main"))
        ])
        let store = RemoteExplorerStateStore()
        store.loadedRepositories = [PersistedRepositoryState(
            canonicalName: "devhq",
            rootPath: "/cache/build/devhq",
            gitDirectoryPath: "/cache/build/devhq/.git",
            isExpanded: true,
            worktrees: [],
            server: source.server,
            remotePath: source.remotePath,
            lastSyncError: "first synchronization failed"
        )]
        let model = WorktreeExplorerModel(
            discoverer: RemoteExplorerDiscoverer(),
            remoteService: service,
            onActivate: { _, _ in },
            stateStore: store
        )

        model.restore(activateSelection: false)
        XCTAssertEqual(model.repositories[0].worktrees, [])
        XCTAssertEqual(model.repositories[0].lastSyncError, "first synchronization failed")

        await model.synchronizeRemoteRepositories()

        XCTAssertEqual(
            service.synchronizationContexts.map(\.allowExistingCloneReferenceReuse),
            [true]
        )
        XCTAssertEqual(model.repositories[0].worktrees.map(\.name), ["main"])
    }

    @MainActor
    func testLocalAndRemoteRepositoriesWithSameNameShareVisualRoot() async throws {
        let localRoot = URL(fileURLWithPath: "/repos/devhq")
        let local = GitRepositoryInfo(
            rootURL: localRoot,
            name: "devhq",
            gitDirectoryURL: localRoot.appendingPathComponent(".git"),
            worktrees: [GitWorktreeInfo(name: "main", url: localRoot, isMain: true)]
        )
        let discoverer = RemoteExplorerDiscoverer()
        discoverer.repositories[localRoot.standardizedFileURL.path] = local
        let source = try SSHRemoteRepositorySource(server: "build", remotePath: "/srv/devhq")
        let service = RemoteExplorerServiceStub(results: [
            .success(remoteSnapshot(source: source, branch: "develop"))
        ])
        let model = WorktreeExplorerModel(
            discoverer: discoverer,
            remoteService: service,
            onActivate: { _, _ in },
            watcherFactory: { _, _ in RemoteExplorerWatcher() }
        )

        try model.addRepository(localRoot)
        try await model.addRemoteRepository(source.specification)

        XCTAssertEqual(model.repositories.count, 2)
        XCTAssertEqual(model.tree.roots.count, 1)
        XCTAssertEqual(model.tree.roots[0].children?.map(\.value.name), ["main", "[build] develop"])
    }

    @MainActor
    func testRemoteThenLocalSharedRootUsesBasenameWithoutChangingSourceIdentity() async throws {
        let source = try SSHRemoteRepositorySource(server: "build", remotePath: "/srv/devhq")
        let service = RemoteExplorerServiceStub(results: [
            .success(remoteSnapshot(source: source, branch: "develop"))
        ])
        let localRoot = URL(fileURLWithPath: "/repos/devhq")
        let local = GitRepositoryInfo(
            rootURL: localRoot,
            name: "devhq",
            gitDirectoryURL: localRoot.appendingPathComponent(".git"),
            worktrees: [GitWorktreeInfo(name: "main", url: localRoot, isMain: true)]
        )
        let discoverer = RemoteExplorerDiscoverer()
        discoverer.repositories[localRoot.standardizedFileURL.path] = local
        let model = WorktreeExplorerModel(
            discoverer: discoverer,
            remoteService: service,
            onActivate: { _, _ in },
            watcherFactory: { _, _ in RemoteExplorerWatcher() }
        )

        try await model.addRemoteRepository(source.specification)
        try model.addRepository(localRoot)

        XCTAssertEqual(model.repositories.map(\.canonicalName), ["devhq", "devhq-2"])
        XCTAssertEqual(model.tree.roots.count, 1)
        XCTAssertEqual(model.tree.roots[0].value.name, "devhq")
        XCTAssertEqual(model.tree.roots[0].id, .repository(local.id))
        XCTAssertEqual(
            model.tree.roots[0].children?.map(\.value.name),
            ["[build] develop", "main"]
        )
    }

    private func remoteSnapshot(
        source: SSHRemoteRepositorySource,
        branch: String
    ) -> SSHRemoteRepositorySnapshot {
        let root = URL(fileURLWithPath: "/cache/devhq/remote-mirrors/\(source.server)/devhq")
        return SSHRemoteRepositorySnapshot(
            source: source,
            rootURL: root,
            gitDirectoryURL: root.appendingPathComponent(".git"),
            worktrees: [SSHRemoteWorktreeSnapshot(
                name: branch,
                localURL: root,
                remotePath: source.remotePath,
                isMain: true,
                head: "abc123"
            )]
        )
    }
}

private final class RemoteExplorerWatcher: RepositoryWatching {
    func cancel() {}
}
