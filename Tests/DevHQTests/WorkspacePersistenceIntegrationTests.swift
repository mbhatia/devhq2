import Foundation
import XCTest
@testable import DevHQ

final class WorkspacePersistenceIntegrationTests: XCTestCase {
    @MainActor
    func testPersistenceRoundTripAcrossExplorerAndWorkspaceModels() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let configDirectory = temporaryRoot.appendingPathComponent("config", isDirectory: true)
        let cacheDirectory = temporaryRoot.appendingPathComponent("cache", isDirectory: true)
        let firstRepositoryRoot = temporaryRoot
            .appendingPathComponent("first/devhq", isDirectory: true)
        let secondRepositoryRoot = temporaryRoot
            .appendingPathComponent("second/devhq", isDirectory: true)
        let featureWorktreeRoot = temporaryRoot
            .appendingPathComponent("worktrees/bootstrap", isDirectory: true)
        let featureSources = featureWorktreeRoot
            .appendingPathComponent("Sources/Feature", isDirectory: true)
        for directory in [
            firstRepositoryRoot,
            secondRepositoryRoot,
            featureSources,
            firstRepositoryRoot.appendingPathComponent(".git", isDirectory: true),
            secondRepositoryRoot.appendingPathComponent(".git", isDirectory: true)
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let firstFile = featureSources.appendingPathComponent("First.swift")
        let secondFile = featureSources.appendingPathComponent("Second.swift")
        try "let first = 1".write(to: firstFile, atomically: true, encoding: .utf8)
        try "let second = 1".write(to: secondFile, atomically: true, encoding: .utf8)

        let firstRepository = repository(
            root: firstRepositoryRoot,
            worktrees: [
                worktree("main", at: firstRepositoryRoot, isMain: true),
                worktree("feature/bootstrap", at: featureWorktreeRoot)
            ]
        )
        let secondRepository = repository(
            root: secondRepositoryRoot,
            worktrees: [worktree("main", at: secondRepositoryRoot, isMain: true)]
        )
        let store = WorkspaceStateStore(
            configDirectory: configDirectory,
            cacheDirectory: cacheDirectory
        )
        let discoverer = RecordingWorktreeDiscoverer([firstRepository, secondRepository])
        let workspace = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)
        let explorer = WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { repository, worktree in
                workspace.openWorktree(
                    canonicalRepositoryName: repository.canonicalName,
                    worktreeName: worktree.name,
                    url: worktree.url
                )
            },
            stateStore: store,
            watcherFactory: { _, _ in NoOpRepositoryWatcher() },
            eventDelivery: { $0() }
        )

        try explorer.addRepository(firstRepositoryRoot)
        try explorer.addRepository(secondRepositoryRoot)

        XCTAssertEqual(explorer.repositories.map(\.canonicalName), ["devhq", "devhq-2"])
        let repositoryLines = try String(
            contentsOf: store.repositoriesFileURL,
            encoding: .utf8
        ).split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(repositoryLines.count, 2)
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try repositoryLines.map {
                try decoder.decode(PersistedRepositoryState.self, from: Data($0.utf8))
            }.map(\.canonicalName),
            ["devhq", "devhq-2"]
        )

        let firstRootNode = explorer.tree.roots[0]
        explorer.toggle(firstRootNode)
        XCTAssertFalse(explorer.tree.isExpanded(firstRootNode))
        let featureNode = try XCTUnwrap(firstRootNode.children?.first(where: {
            $0.value.name == "feature/bootstrap"
        }))
        explorer.activate(featureNode)
        XCTAssertEqual(workspace.rootURL, featureWorktreeRoot.standardizedFileURL)

        workspace.openFile(firstFile)
        workspace.openFile(secondFile)
        workspace.selectedDocument?.text = "let second = 2"
        workspace.fileTree.restoreExpandedIDs(["Sources", "Sources/Feature"])

        let secondMainNode = try XCTUnwrap(explorer.tree.roots[1].children?.first)
        explorer.activate(secondMainNode)

        let featureStateURL = cacheDirectory
            .appendingPathComponent("devhq", isDirectory: true)
            .appendingPathComponent("feature_bootstrap.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: featureStateURL.path))
        let switchedState = try decoder.decode(
            PersistedWorkspaceState.self,
            from: Data(contentsOf: featureStateURL)
        )
        XCTAssertEqual(switchedState.expandedFileNodeIDs, ["Sources", "Sources/Feature"])
        XCTAssertEqual(switchedState.tabs.map(\.path), [
            "Sources/Feature/First.swift",
            "Sources/Feature/Second.swift"
        ])
        XCTAssertEqual(switchedState.selectedTabPath, "Sources/Feature/Second.swift")
        XCTAssertEqual(switchedState.tabs.last?.unsavedText, "let second = 2")

        explorer.activate(featureNode)
        XCTAssertEqual(workspace.documents.map(\.url), [firstFile, secondFile])
        XCTAssertEqual(workspace.selectedDocument?.url, secondFile)
        XCTAssertEqual(workspace.selectedDocument?.text, "let second = 2")
        XCTAssertEqual(workspace.fileTree.expandedIDs, ["Sources", "Sources/Feature"])

        workspace.selectedDocument?.text = "let second = 3"
        workspace.select(workspace.documents[0])
        workspace.fileTree.restoreExpandedIDs(["Sources"])
        workspace.saveCurrentWorkspaceState()

        let terminatedState = try decoder.decode(
            PersistedWorkspaceState.self,
            from: Data(contentsOf: featureStateURL)
        )
        XCTAssertEqual(terminatedState.expandedFileNodeIDs, ["Sources"])
        XCTAssertEqual(terminatedState.selectedTabPath, "Sources/Feature/First.swift")
        XCTAssertEqual(terminatedState.tabs.last?.unsavedText, "let second = 3")

        let currentSecondRepository = repository(
            root: secondRepositoryRoot,
            worktrees: [
                worktree("main", at: secondRepositoryRoot, isMain: true),
                worktree(
                    "current/discovery",
                    at: temporaryRoot.appendingPathComponent("worktrees/current")
                )
            ]
        )
        let freshStore = WorkspaceStateStore(
            configDirectory: configDirectory,
            cacheDirectory: cacheDirectory
        )
        let freshDiscoverer = RecordingWorktreeDiscoverer([
            firstRepository,
            currentSecondRepository
        ])
        let freshWorkspace = WorkspaceModel(arguments: ["DevHQ"], stateStore: freshStore)
        let freshExplorer = WorktreeExplorerModel(
            discoverer: freshDiscoverer,
            onActivate: { repository, worktree in
                freshWorkspace.openWorktree(
                    canonicalRepositoryName: repository.canonicalName,
                    worktreeName: worktree.name,
                    url: worktree.url
                )
            },
            stateStore: freshStore,
            watcherFactory: { _, _ in NoOpRepositoryWatcher() },
            eventDelivery: { $0() }
        )

        freshExplorer.restore()

        XCTAssertEqual(freshDiscoverer.discoveredURLs, [
            firstRepositoryRoot.standardizedFileURL,
            secondRepositoryRoot.standardizedFileURL
        ])
        XCTAssertEqual(freshExplorer.repositories.map(\.canonicalName), ["devhq", "devhq-2"])
        XCTAssertEqual(
            freshExplorer.repositories[1].worktrees.map(\.name),
            ["main", "current/discovery"],
            "Startup must rediscover current worktrees instead of trusting the saved list"
        )
        XCTAssertFalse(freshExplorer.tree.isExpanded(freshExplorer.tree.roots[0]))
        XCTAssertTrue(freshExplorer.tree.isExpanded(freshExplorer.tree.roots[1]))
        XCTAssertEqual(freshExplorer.selectedWorktreeID, featureWorktreeRoot.standardizedFileURL.path)
        XCTAssertEqual(freshWorkspace.rootURL, featureWorktreeRoot.standardizedFileURL)
        XCTAssertEqual(freshWorkspace.documents.map(\.url), [firstFile, secondFile])
        XCTAssertEqual(freshWorkspace.selectedDocument?.url, firstFile)
        XCTAssertEqual(freshWorkspace.documents.last?.text, "let second = 3")
        XCTAssertTrue(freshWorkspace.documents.last?.isDirty == true)
        XCTAssertEqual(freshWorkspace.fileTree.expandedIDs, ["Sources"])
    }

    private func repository(
        root: URL,
        worktrees: [GitWorktreeInfo]
    ) -> GitRepositoryInfo {
        GitRepositoryInfo(
            rootURL: root,
            name: root.lastPathComponent,
            gitDirectoryURL: root.appendingPathComponent(".git", isDirectory: true),
            worktrees: worktrees
        )
    }

    private func worktree(
        _ name: String,
        at url: URL,
        isMain: Bool = false
    ) -> GitWorktreeInfo {
        GitWorktreeInfo(name: name, url: url, isMain: isMain)
    }
}

private final class RecordingWorktreeDiscoverer: GitWorktreeDiscovering {
    private let repositoriesByPath: [String: GitRepositoryInfo]
    private(set) var discoveredURLs: [URL] = []

    init(_ repositories: [GitRepositoryInfo]) {
        repositoriesByPath = Dictionary(uniqueKeysWithValues: repositories.map {
            ($0.rootURL.standardizedFileURL.path, $0)
        })
    }

    func discover(at url: URL) throws -> GitRepositoryInfo {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        discoveredURLs.append(url)
        guard let repository = repositoriesByPath[url.path] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return repository
    }
}

private final class NoOpRepositoryWatcher: RepositoryWatching {
    func cancel() {}
}
