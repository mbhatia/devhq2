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

final class WorktreeExplorerModelTests: XCTestCase {
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
}
