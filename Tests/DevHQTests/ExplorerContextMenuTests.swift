import Foundation
import XCTest
@testable import DevHQ

private final class ContextMenuTestDiscoverer: GitWorktreeDiscovering {
    var repository: GitRepositoryInfo

    init(repository: GitRepositoryInfo) {
        self.repository = repository
    }

    func discover(at url: URL) throws -> GitRepositoryInfo {
        repository
    }
}

private final class ContextMenuTestWatcher: RepositoryWatching {
    func cancel() {}
}

private final class ContextMenuTestWorktreeManager: GitWorktreeManaging {
    var created: (repository: URL, branch: String, destination: URL)?
    var deleted: (repository: URL, worktree: URL)?
    var onCreate: (() -> Void)?
    var onDelete: (() -> Void)?

    func createWorktree(
        in repositoryURL: URL,
        branchName: String,
        at worktreeURL: URL
    ) throws -> GitWorktreeInfo {
        created = (repositoryURL, branchName, worktreeURL)
        onCreate?()
        return GitWorktreeInfo(name: branchName, url: worktreeURL, isMain: false)
    }

    func deleteWorktree(in repositoryURL: URL, at worktreeURL: URL) throws {
        deleted = (repositoryURL, worktreeURL)
        onDelete?()
    }
}

final class ExplorerContextMenuTests: XCTestCase {
    func testWorktreeCreationURLUsesConfiguredRelativeAndAbsolutePaths() {
        let repository = URL(fileURLWithPath: "/repos/project", isDirectory: true)

        XCTAssertEqual(
            worktreeCreationURL(
                repositoryRootURL: repository,
                configuredPath: ".worktrees",
                branchName: "feature/menu"
            ).path,
            "/repos/project/.worktrees/feature/menu"
        )
        XCTAssertEqual(
            worktreeCreationURL(
                repositoryRootURL: repository,
                configuredPath: "/tmp/devhq-worktrees",
                branchName: "topic"
            ).path,
            "/tmp/devhq-worktrees/topic"
        )
    }

    @MainActor
    func testCreateWorktreeUsesCurrentSettingAndRefreshesExplorer() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let discoverer = ContextMenuTestDiscoverer(repository: fixture.repository)
        let explorer = makeExplorer(discoverer: discoverer)
        try explorer.addRepository(fixture.main)
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let settings = EditorSettings()
        settings.gitWorktreePath = "trees"
        let manager = ContextMenuTestWorktreeManager()
        let createdURL = fixture.main.appendingPathComponent(
            "trees/feature/menu",
            isDirectory: true
        )
        manager.onCreate = {
            discoverer.repository = self.repository(
                main: fixture.main,
                worktrees: [
                    GitWorktreeInfo(name: "main", url: fixture.main, isMain: true),
                    GitWorktreeInfo(name: "feature/menu", url: createdURL, isMain: false)
                ]
            )
        }
        let registry = ContextMenuRegistry()
        registerBuiltInContextMenus(
            in: registry,
            workspace: workspace,
            worktreeExplorer: explorer,
            settings: settings,
            worktreeManager: manager,
            promptForBranchName: { "feature/menu" }
        )

        let snapshot = try XCTUnwrap(worktreeContextMenuSnapshot(
            for: explorer.tree.roots[0],
            in: explorer
        ))
        try XCTUnwrap(registry.registeredItems.first {
            $0.id == BuiltInContextMenuID.createWorktree
        }).perform(with: snapshot)

        XCTAssertEqual(manager.created?.repository, fixture.main)
        XCTAssertEqual(manager.created?.branch, "feature/menu")
        XCTAssertEqual(manager.created?.destination.path, createdURL.path)
        XCTAssertEqual(explorer.repositories[0].worktrees.map(\.name), ["main", "feature/menu"])
    }

    @MainActor
    func testDeleteWorktreeClosesActiveWorkspaceAndRefreshesExplorer() throws {
        let fixture = makeFixture(includeLinkedWorktree: true)
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let discoverer = ContextMenuTestDiscoverer(repository: fixture.repository)
        let explorer = makeExplorer(discoverer: discoverer)
        try explorer.addRepository(fixture.main)
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(fixture.linked)
        let manager = ContextMenuTestWorktreeManager()
        manager.onDelete = {
            discoverer.repository = self.repository(
                main: fixture.main,
                worktrees: [GitWorktreeInfo(name: "main", url: fixture.main, isMain: true)]
            )
        }
        let registry = ContextMenuRegistry()
        registerBuiltInContextMenus(
            in: registry,
            workspace: workspace,
            worktreeExplorer: explorer,
            settings: EditorSettings(),
            worktreeManager: manager
        )

        let worktreeNode = try XCTUnwrap(explorer.tree.roots[0].children?[1])
        let snapshot = try XCTUnwrap(worktreeContextMenuSnapshot(
            for: worktreeNode,
            in: explorer
        ))
        try XCTUnwrap(registry.registeredItems.first {
            $0.id == BuiltInContextMenuID.deleteWorktree
        }).perform(with: snapshot)

        XCTAssertEqual(manager.deleted?.worktree, fixture.linked)
        XCTAssertNil(workspace.rootURL)
        XCTAssertEqual(explorer.repositories[0].worktrees.map(\.name), ["main"])
    }

    @MainActor
    func testRemoveRepositoryClosesItsActiveWorktree() throws {
        let fixture = makeFixture(includeLinkedWorktree: true)
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let explorer = makeExplorer(
            discoverer: ContextMenuTestDiscoverer(repository: fixture.repository)
        )
        try explorer.addRepository(fixture.main)
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(fixture.linked)
        let registry = ContextMenuRegistry()
        registerBuiltInContextMenus(
            in: registry,
            workspace: workspace,
            worktreeExplorer: explorer,
            settings: EditorSettings(),
            worktreeManager: ContextMenuTestWorktreeManager()
        )

        let snapshot = try XCTUnwrap(worktreeContextMenuSnapshot(
            for: explorer.tree.roots[0],
            in: explorer
        ))
        try XCTUnwrap(registry.registeredItems.first {
            $0.id == BuiltInContextMenuID.removeRepository
        }).perform(with: snapshot)

        XCTAssertNil(workspace.rootURL)
        XCTAssertTrue(explorer.repositories.isEmpty)
    }

    @MainActor
    func testRemoveRepositoryRefusesToDiscardActiveUnsavedDocuments() throws {
        let fixture = makeFixture(includeLinkedWorktree: true)
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let file = fixture.linked.appendingPathComponent("Unsaved.txt")
        try "saved".write(to: file, atomically: true, encoding: .utf8)
        let explorer = makeExplorer(
            discoverer: ContextMenuTestDiscoverer(repository: fixture.repository)
        )
        try explorer.addRepository(fixture.main)
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(fixture.linked)
        workspace.openFile(file)
        workspace.selectedDocument?.text = "changed"
        let registry = ContextMenuRegistry()
        registerBuiltInContextMenus(
            in: registry,
            workspace: workspace,
            worktreeExplorer: explorer,
            settings: EditorSettings(),
            worktreeManager: ContextMenuTestWorktreeManager()
        )
        let snapshot = try XCTUnwrap(worktreeContextMenuSnapshot(
            for: explorer.tree.roots[0],
            in: explorer
        ))
        let action = try XCTUnwrap(registry.registeredItems.first {
            $0.id == BuiltInContextMenuID.removeRepository
        })

        XCTAssertThrowsError(try action.perform(with: snapshot)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unsaved documents"))
        }
        XCTAssertEqual(workspace.rootURL, fixture.linked)
        XCTAssertEqual(explorer.repositories.count, 1)
    }

    @MainActor
    func testDeleteWorktreeRefusesToDiscardCachedUnsavedDocuments() throws {
        let fixture = makeFixture(includeLinkedWorktree: true)
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let file = fixture.linked.appendingPathComponent("Unsaved.txt")
        try "saved".write(to: file, atomically: true, encoding: .utf8)
        let explorer = makeExplorer(
            discoverer: ContextMenuTestDiscoverer(repository: fixture.repository)
        )
        try explorer.addRepository(fixture.main)
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(fixture.linked)
        workspace.openFile(file)
        workspace.selectedDocument?.text = "changed"
        workspace.openWorkspace(fixture.main)
        let manager = ContextMenuTestWorktreeManager()
        let registry = ContextMenuRegistry()
        registerBuiltInContextMenus(
            in: registry,
            workspace: workspace,
            worktreeExplorer: explorer,
            settings: EditorSettings(),
            worktreeManager: manager
        )
        let linkedNode = try XCTUnwrap(explorer.tree.roots[0].children?[1])
        let snapshot = try XCTUnwrap(worktreeContextMenuSnapshot(
            for: linkedNode,
            in: explorer
        ))
        let action = try XCTUnwrap(registry.registeredItems.first {
            $0.id == BuiltInContextMenuID.deleteWorktree
        })

        XCTAssertThrowsError(try action.perform(with: snapshot)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unsaved documents"))
        }
        XCTAssertNil(manager.deleted)
        XCTAssertEqual(workspace.rootURL, fixture.main)
        XCTAssertEqual(explorer.repositories[0].worktrees.count, 2)
    }

    @MainActor
    func testFileActionsUseClickedNodeSnapshot() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let file = fixture.main.appendingPathComponent("README.md")
        try "test".write(to: file, atomically: true, encoding: .utf8)
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let explorer = makeExplorer(
            discoverer: ContextMenuTestDiscoverer(repository: fixture.repository)
        )
        var opened: [(URL, Bool)] = []
        let registry = ContextMenuRegistry()
        registerBuiltInContextMenus(
            in: registry,
            workspace: workspace,
            worktreeExplorer: explorer,
            settings: EditorSettings(),
            worktreeManager: ContextMenuTestWorktreeManager(),
            openInSystemViewer: { opened.append(($0, $1)) }
        )
        let action = try XCTUnwrap(registry.registeredItems.first {
            $0.id == BuiltInContextMenuID.openInSystemViewer
        })

        try action.perform(with: ContextMenuSnapshot(
            target: .fileDirectory,
            name: "project",
            path: fixture.main.path
        ))
        try action.perform(with: ContextMenuSnapshot(
            target: .fileFile,
            name: "README.md",
            path: file.path
        ))

        XCTAssertEqual(opened.map(\.0), [fixture.main, file])
        XCTAssertEqual(opened.map(\.1), [true, false])
    }

    @MainActor
    func testMainWorktreeDeleteEntryIsDisabled() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let explorer = makeExplorer(
            discoverer: ContextMenuTestDiscoverer(repository: fixture.repository)
        )
        try explorer.addRepository(fixture.main)
        let registry = ContextMenuRegistry()
        registerBuiltInContextMenus(
            in: registry,
            workspace: WorkspaceModel(arguments: ["DevHQ"]),
            worktreeExplorer: explorer,
            settings: EditorSettings(),
            worktreeManager: ContextMenuTestWorktreeManager()
        )
        let mainNode = try XCTUnwrap(explorer.tree.roots[0].children?.first)
        let snapshot = try XCTUnwrap(worktreeContextMenuSnapshot(for: mainNode, in: explorer))

        let entries = treeContextMenuEntries(
            for: snapshot,
            registry: registry,
            onError: { _ in }
        )

        XCTAssertEqual(
            entries.first { $0.id == BuiltInContextMenuID.deleteWorktree }?.isEnabled,
            false
        )
    }

    @MainActor
    private func makeExplorer(
        discoverer: ContextMenuTestDiscoverer
    ) -> WorktreeExplorerModel {
        WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { _, _ in },
            watcherFactory: { _, _ in ContextMenuTestWatcher() },
            eventDelivery: { $0() }
        )
    }

    private func makeFixture(
        includeLinkedWorktree: Bool = false
    ) -> (container: URL, main: URL, linked: URL, repository: GitRepositoryInfo) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let main = container.appendingPathComponent("project", isDirectory: true)
        let linked = container.appendingPathComponent("linked", isDirectory: true)
        try! FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        if includeLinkedWorktree {
            try! FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        }
        let worktrees = [GitWorktreeInfo(name: "main", url: main, isMain: true)]
            + (includeLinkedWorktree
                ? [GitWorktreeInfo(name: "feature", url: linked, isMain: false)]
                : [])
        return (container, main, linked, repository(main: main, worktrees: worktrees))
    }

    private func repository(
        main: URL,
        worktrees: [GitWorktreeInfo]
    ) -> GitRepositoryInfo {
        GitRepositoryInfo(
            rootURL: main,
            name: "project",
            gitDirectoryURL: main.appendingPathComponent(".git", isDirectory: true),
            worktrees: worktrees
        )
    }
}
