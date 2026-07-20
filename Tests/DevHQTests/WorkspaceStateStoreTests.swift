import Foundation
import XCTest
@testable import DevHQ

final class WorkspaceStateStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var configDirectory: URL!
    private var cacheDirectory: URL!
    private var store: WorkspaceStateStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        configDirectory = temporaryDirectory.appendingPathComponent("config", isDirectory: true)
        cacheDirectory = temporaryDirectory.appendingPathComponent("cache", isDirectory: true)
        store = WorkspaceStateStore(
            configDirectory: configDirectory,
            cacheDirectory: cacheDirectory
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        store = nil
        cacheDirectory = nil
        configDirectory = nil
        temporaryDirectory = nil
    }

    func testDefaultPathsUseDevHQConfigAndCacheDirectories() {
        let defaultStore = WorkspaceStateStore()
        let home = FileManager.default.homeDirectoryForCurrentUser

        XCTAssertEqual(
            defaultStore.repositoriesFileURL,
            home.appendingPathComponent(".config/devhq/ws/repos.jsonl")
        )
        XCTAssertEqual(
            defaultStore.worktreeStateFileURL(
                canonicalRepositoryName: "devhq",
                worktreeName: "feature/bootstrap"
            ),
            home.appendingPathComponent(".cache/devhq/ws/devhq/feature_bootstrap.json")
        )
    }

    func testRepositoriesAreStoredAsOneJSONObjectPerLineInInputOrder() throws {
        let repositories = [
            repository(name: "first", root: "/repos/first", selected: false),
            repository(name: "second", root: "/repos/second", selected: true)
        ]

        try store.saveRepositories(repositories)

        let contents = try String(contentsOf: store.repositoriesFileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)

        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(PersistedRepositoryState.self, from: Data(lines[0].utf8)),
            repositories[0]
        )
        XCTAssertEqual(
            try decoder.decode(PersistedRepositoryState.self, from: Data(lines[1].utf8)),
            repositories[1]
        )
        XCTAssertEqual(try store.loadRepositories(), repositories)
    }

    func testEmptyRepositoriesCreateAnEmptyFileAndLoadAsEmpty() throws {
        try store.saveRepositories([])

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.repositoriesFileURL.path))
        XCTAssertEqual(try Data(contentsOf: store.repositoriesFileURL), Data())
        XCTAssertEqual(try store.loadRepositories(), [])
    }

    func testLoadingMissingFilesReturnsEmptyState() throws {
        XCTAssertEqual(try store.loadRepositories(), [])
        XCTAssertNil(
            try store.loadWorkspaceState(
                canonicalRepositoryName: "devhq",
                worktreeName: "main"
            )
        )
    }

    func testSavingCreatesDirectoriesAndRoundTripsWorktreeState() throws {
        let state = workspaceState(selectedPath: "/repos/devhq/Sources/App.swift")

        try store.saveWorkspaceState(
            state,
            canonicalRepositoryName: "devhq",
            worktreeName: "feature/bootstrap"
        )

        let expectedURL = cacheDirectory
            .appendingPathComponent("devhq", isDirectory: true)
            .appendingPathComponent("feature_bootstrap.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))
        XCTAssertEqual(
            try store.loadWorkspaceState(
                canonicalRepositoryName: "devhq",
                worktreeName: "feature/bootstrap"
            ),
            state
        )
    }

    func testBranchFilenameReplacesEverySlash() {
        XCTAssertEqual(
            WorkspaceStateStore.worktreeFileName(for: "feature/user/bootstrap"),
            "feature_user_bootstrap.json"
        )
    }

    func testSavingRepositoriesOverwritesPreviousContents() throws {
        try store.saveRepositories([
            repository(name: "old", root: "/repos/old", selected: false)
        ])
        let replacement = repository(name: "new", root: "/repos/new", selected: true)

        try store.saveRepositories([replacement])

        XCTAssertEqual(try store.loadRepositories(), [replacement])
        let contents = try String(contentsOf: store.repositoriesFileURL, encoding: .utf8)
        XCTAssertEqual(contents.split(separator: "\n").count, 1)
        XCTAssertFalse(contents.contains("/repos/old"))
    }

    func testSavingWorktreeStateOverwritesPreviousContents() throws {
        let first = workspaceState(selectedPath: "/repos/devhq/First.swift")
        let replacement = workspaceState(selectedPath: "/repos/devhq/Second.swift")
        try store.saveWorkspaceState(
            first,
            canonicalRepositoryName: "devhq",
            worktreeName: "main"
        )

        try store.saveWorkspaceState(
            replacement,
            canonicalRepositoryName: "devhq",
            worktreeName: "main"
        )

        XCTAssertEqual(
            try store.loadWorkspaceState(
                canonicalRepositoryName: "devhq",
                worktreeName: "main"
            ),
            replacement
        )
    }

    private func repository(
        name: String,
        root: String,
        selected: Bool
    ) -> PersistedRepositoryState {
        PersistedRepositoryState(
            canonicalName: name,
            rootPath: root,
            gitDirectoryPath: root + "/.git",
            isExpanded: true,
            worktrees: [
                PersistedWorktreeState(
                    branchName: "main",
                    path: root,
                    isMain: true,
                    isExpanded: false,
                    isSelected: selected
                )
            ]
        )
    }

    private func workspaceState(selectedPath: String) -> PersistedWorkspaceState {
        PersistedWorkspaceState(
            expandedFileNodeIDs: ["Sources", "Sources/Features"],
            tabs: [
                PersistedEditorTabState(
                    path: selectedPath,
                    unsavedText: "edited",
                    savedText: "original"
                )
            ],
            selectedTabPath: selectedPath
        )
    }
}
