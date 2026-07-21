import Foundation
import XCTest
@testable import DevHQ

final class BuiltInCommandsTests: XCTestCase {
    @MainActor
    func testRegistrationDefinesExpectedIdentifiersTitlesScopesAndAvailability() throws {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let explorer = makeExplorer()
        let manager = CommandManager()
        try registerBuiltInCommands(
            in: manager,
            workspace: workspace,
            worktreeExplorer: explorer,
            pickers: cancellingPickers()
        )

        XCTAssertEqual(Set(manager.commandsByID.keys), [
            "devhq:open-remote-repo", "devhq:sync-remote-repos",
            "worktree:add-repo", "file:new", "file:new-dir", "file:close",
            "terminal:new", "terminal:close", "agent:create", "git:toggle-diff",
            "git:filter-full", "git:filter-uncommitted", "git:filter-staged",
            "git:filter-head"
        ])
        XCTAssertEqual(manager.commandsByID["agent:create"]?.title, "agent: create")
        XCTAssertEqual(
            manager.commandsByID["devhq:open-remote-repo"]?.title,
            "devhq: open remote repo"
        )
        XCTAssertEqual(
            manager.commandsByID["devhq:sync-remote-repos"]?.title,
            "devhq: sync remote repos"
        )
        XCTAssertEqual(manager.commandsByID["worktree:add-repo"]?.title, "worktree: add repo")
        XCTAssertEqual(manager.commandsByID["file:new"]?.title, "file: new")
        XCTAssertEqual(manager.commandsByID["file:new-dir"]?.title, "file: new dir")
        XCTAssertEqual(manager.commandsByID["file:close"]?.title, "file: close")
        XCTAssertEqual(manager.commandsByID["terminal:new"]?.title, "terminal: new")
        XCTAssertEqual(manager.commandsByID["terminal:close"]?.title, "terminal: close")
        XCTAssertEqual(manager.commandsByID["git:filter-full"]?.title, "git: filter full")
        XCTAssertEqual(manager.commandsByID["git:toggle-diff"]?.title, "git: toggle diff")
        XCTAssertEqual(
            manager.commandsByID["worktree:add-repo"]?.viewKinds,
            Set(CommandViewKind.allCases)
        )
        XCTAssertEqual(
            manager.commandsByID["devhq:open-remote-repo"]?.viewKinds,
            Set(CommandViewKind.allCases)
        )
        XCTAssertEqual(
            manager.commandsByID["devhq:sync-remote-repos"]?.viewKinds,
            Set(CommandViewKind.allCases)
        )
        XCTAssertEqual(manager.commandsByID["file:new"]?.viewKinds, [.file, .document])
        XCTAssertEqual(manager.commandsByID["file:new-dir"]?.viewKinds, [.file, .document])
        XCTAssertEqual(manager.commandsByID["file:close"]?.viewKinds, [.document])
        XCTAssertEqual(manager.commandsByID["terminal:new"]?.viewKinds, Set(CommandViewKind.allCases))
        XCTAssertEqual(manager.commandsByID["terminal:close"]?.viewKinds, [.terminal])
        XCTAssertEqual(manager.commandsByID["agent:create"]?.viewKinds, Set(CommandViewKind.allCases))
        XCTAssertEqual(
            manager.commandsByID["git:filter-uncommitted"]?.viewKinds,
            Set(CommandViewKind.allCases)
        )
        XCTAssertEqual(
            manager.commandsByID["git:toggle-diff"]?.viewKinds,
            Set(CommandViewKind.allCases)
        )

        for view in CommandViewKind.allCases {
            XCTAssertEqual(
                try manager.commands(in: CommandContext(view: view)).map(\.id),
                ["devhq:open-remote-repo", "devhq:sync-remote-repos", "worktree:add-repo"]
            )
        }

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.openWorkspace(root)
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .file)).map(\.id),
            [
                "devhq:open-remote-repo", "devhq:sync-remote-repos", "file:new",
                "file:new-dir", "git:filter-full", "git:filter-head",
                "git:filter-staged", "git:filter-uncommitted", "git:toggle-diff",
                "terminal:new", "worktree:add-repo"
            ]
        )
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .document)).map(\.id),
            [
                "devhq:open-remote-repo", "devhq:sync-remote-repos", "file:new",
                "file:new-dir", "git:filter-full", "git:filter-head",
                "git:filter-staged", "git:filter-uncommitted", "git:toggle-diff",
                "terminal:new", "worktree:add-repo"
            ]
        )

        let existingFile = root.appendingPathComponent("Open.swift")
        try "let open = true".write(to: existingFile, atomically: true, encoding: .utf8)
        workspace.openFile(existingFile)
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .document)).map(\.id),
            [
                "devhq:open-remote-repo", "devhq:sync-remote-repos", "file:close",
                "file:new", "file:new-dir", "git:filter-full",
                "git:filter-head", "git:filter-staged", "git:filter-uncommitted",
                "git:toggle-diff", "terminal:new", "worktree:add-repo"
            ]
        )
    }

    @MainActor
    func testCommandsExecuteAgainstExplorerAndWorkspaceModels() throws {
        let root = try temporaryDirectory(named: "repository")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        let repository = GitRepositoryInfo(
            rootURL: root,
            name: root.lastPathComponent,
            gitDirectoryURL: gitDirectory,
            worktrees: [GitWorktreeInfo(name: "main", url: root, isMain: true)]
        )
        let discoverer = BuiltInCommandsTestDiscoverer(repository: repository)
        let explorer = makeExplorer(discoverer: discoverer)
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(root)
        let newFile = root.appendingPathComponent("Created.swift")
        let newDirectory = root.appendingPathComponent("Generated", isDirectory: true)
        var repositoryPickerCalls = 0
        var filePickerRoots: [URL] = []
        var directoryPickerRoots: [URL] = []
        let pickers = BuiltInCommandPickers(
            repositoryURL: {
                repositoryPickerCalls += 1
                return root
            },
            remoteRepositorySpec: { nil },
            fileURL: { pickerRoot in
                filePickerRoots.append(pickerRoot)
                return newFile
            },
            directoryURL: { pickerRoot in
                directoryPickerRoots.append(pickerRoot)
                return newDirectory
            }
        )
        let manager = CommandManager()
        try registerBuiltInCommands(
            in: manager,
            workspace: workspace,
            worktreeExplorer: explorer,
            pickers: pickers
        )

        try manager.execute(id: "git:filter-staged", in: CommandContext(view: .file))
        XCTAssertEqual(workspace.fileFilterMode, .staged)
        XCTAssertTrue(workspace.isDiffOverlayEnabled)
        try manager.execute(id: "git:toggle-diff", in: CommandContext(view: .document))
        XCTAssertFalse(workspace.isDiffOverlayEnabled)

        try manager.execute(id: "worktree:add-repo", in: CommandContext(view: .document))
        XCTAssertEqual(repositoryPickerCalls, 1)
        XCTAssertEqual(discoverer.discoveredURLs, [root.standardizedFileURL])
        XCTAssertEqual(explorer.repositories.map(\.id), [repository.id])
        XCTAssertEqual(explorer.selectedWorktreeID, repository.worktrees[0].id)

        try manager.execute(id: "file:new", in: CommandContext(view: .file))
        XCTAssertEqual(filePickerRoots, [root.standardizedFileURL.resolvingSymlinksInPath()])
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path))
        XCTAssertEqual(workspace.selectedDocument?.url, newFile.standardizedFileURL)

        try manager.execute(id: "file:new-dir", in: CommandContext(view: .document))
        XCTAssertEqual(directoryPickerRoots, [root.standardizedFileURL.resolvingSymlinksInPath()])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: newDirectory.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)

        try manager.execute(id: "file:close", in: CommandContext(view: .document))
        XCTAssertTrue(workspace.documents.isEmpty)
        XCTAssertNil(workspace.selectedDocument)
    }

    @MainActor
    func testRemoteCommandsOpenAndSynchronizeRepository() async throws {
        let mirrorRoot = try temporaryDirectory(named: "remote")
        defer { try? FileManager.default.removeItem(at: mirrorRoot.deletingLastPathComponent()) }
        let remoteService = BuiltInCommandsTestRemoteService(mirrorRoot: mirrorRoot)
        let explorer = makeExplorer(remoteService: remoteService)
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let manager = CommandManager()
        var pickerCalls = 0
        try registerBuiltInCommands(
            in: manager,
            workspace: workspace,
            worktreeExplorer: explorer,
            pickers: BuiltInCommandPickers(
                repositoryURL: { nil },
                remoteRepositorySpec: {
                    pickerCalls += 1
                    return "git.example.com:/srv/project"
                },
                fileURL: { _ in nil },
                directoryURL: { _ in nil }
            )
        )

        try manager.execute(
            id: "devhq:open-remote-repo",
            in: CommandContext(view: .worktree)
        )
        await waitUntil { explorer.repositories.first?.worktrees.count == 1 }

        XCTAssertEqual(pickerCalls, 1)
        XCTAssertEqual(
            explorer.repositories.first?.remoteSource?.specification,
            "git.example.com:/srv/project"
        )
        var synchronizationCount = await remoteService.synchronizationCount
        XCTAssertEqual(synchronizationCount, 1)

        try manager.execute(
            id: "devhq:sync-remote-repos",
            in: CommandContext(view: .file)
        )
        await waitUntil { await remoteService.synchronizationCount == 2 }
        synchronizationCount = await remoteService.synchronizationCount
        XCTAssertEqual(synchronizationCount, 2)
    }

    @MainActor
    func testCancelledPickersHaveNoModelSideEffects() throws {
        let workspaceRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(workspaceRoot)
        let explorer = makeExplorer()
        var repositoryPickerCalls = 0
        var remoteRepositoryPickerCalls = 0
        var filePickerCalls = 0
        var directoryPickerCalls = 0
        let manager = CommandManager()
        try registerBuiltInCommands(
            in: manager,
            workspace: workspace,
            worktreeExplorer: explorer,
            pickers: BuiltInCommandPickers(
                repositoryURL: {
                    repositoryPickerCalls += 1
                    return nil
                },
                remoteRepositorySpec: {
                    remoteRepositoryPickerCalls += 1
                    return nil
                },
                fileURL: { _ in
                    filePickerCalls += 1
                    return nil
                },
                directoryURL: { _ in
                    directoryPickerCalls += 1
                    return nil
                }
            )
        )

        try manager.execute(id: "worktree:add-repo", in: CommandContext(view: .worktree))
        try manager.execute(id: "devhq:open-remote-repo", in: CommandContext(view: .worktree))
        try manager.execute(id: "file:new", in: CommandContext(view: .file))
        try manager.execute(id: "file:new-dir", in: CommandContext(view: .document))

        XCTAssertEqual(repositoryPickerCalls, 1)
        XCTAssertEqual(remoteRepositoryPickerCalls, 1)
        XCTAssertEqual(filePickerCalls, 1)
        XCTAssertEqual(directoryPickerCalls, 1)
        XCTAssertTrue(explorer.repositories.isEmpty)
        XCTAssertTrue(workspace.documents.isEmpty)
        XCTAssertTrue(workspace.fileTree.roots.isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: workspaceRoot.path),
            []
        )
    }

    @MainActor
    func testRepositoryFailureIsRethrownWithoutLeavingExplorerAlertState() throws {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let explorer = makeExplorer()
        let manager = CommandManager()
        let missingRepository = URL(fileURLWithPath: "/missing/repository", isDirectory: true)
        try registerBuiltInCommands(
            in: manager,
            workspace: workspace,
            worktreeExplorer: explorer,
            pickers: BuiltInCommandPickers(
                repositoryURL: { missingRepository },
                remoteRepositorySpec: { nil },
                fileURL: { _ in nil },
                directoryURL: { _ in nil }
            )
        )

        XCTAssertThrowsError(
            try manager.execute(
                id: "worktree:add-repo",
                in: CommandContext(view: .worktree)
            )
        ) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile)
        }
        XCTAssertNil(explorer.errorMessage)
        XCTAssertTrue(explorer.repositories.isEmpty)
    }

    @MainActor
    func testCreationFailuresAreRethrownWithoutLeavingWorkspaceAlertState() throws {
        let workspaceRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let existingFile = workspaceRoot.appendingPathComponent("Existing.swift")
        let existingDirectory = workspaceRoot.appendingPathComponent("Existing", isDirectory: true)
        try "original".write(to: existingFile, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(workspaceRoot)
        let manager = CommandManager()
        try registerBuiltInCommands(
            in: manager,
            workspace: workspace,
            worktreeExplorer: makeExplorer(),
            pickers: BuiltInCommandPickers(
                repositoryURL: { nil },
                remoteRepositorySpec: { nil },
                fileURL: { _ in existingFile },
                directoryURL: { _ in existingDirectory }
            )
        )

        XCTAssertThrowsError(
            try manager.execute(id: "file:new", in: CommandContext(view: .file))
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceCommandOperationError,
                .targetExists(existingFile.standardizedFileURL.resolvingSymlinksInPath())
            )
        }
        XCTAssertNil(workspace.errorMessage)
        XCTAssertEqual(try String(contentsOf: existingFile, encoding: .utf8), "original")

        XCTAssertThrowsError(
            try manager.execute(id: "file:new-dir", in: CommandContext(view: .document))
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceCommandOperationError,
                .targetExists(existingDirectory.standardizedFileURL.resolvingSymlinksInPath())
            )
        }
        XCTAssertNil(workspace.errorMessage)
    }

    @MainActor
    private func makeExplorer(
        discoverer: any GitWorktreeDiscovering = BuiltInCommandsTestDiscoverer(repository: nil),
        remoteService: (any SSHRemoteRepositoryServicing)? = nil
    ) -> WorktreeExplorerModel {
        WorktreeExplorerModel(
            discoverer: discoverer,
            remoteService: remoteService,
            onActivate: { _, _ in },
            watcherFactory: { _, _ in BuiltInCommandsTestWatcher() },
            eventDelivery: { $0() }
        )
    }

    private func waitUntil(
        attempts: Int = 100,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await predicate() { return }
            await Task.yield()
        }
    }

    private func cancellingPickers() -> BuiltInCommandPickers {
        BuiltInCommandPickers(
            repositoryURL: { nil },
            remoteRepositorySpec: { nil },
            fileURL: { _ in nil },
            directoryURL: { _ in nil }
        )
    }

    private func temporaryDirectory(named name: String = UUID().uuidString) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class BuiltInCommandsTestDiscoverer: GitWorktreeDiscovering {
    let repository: GitRepositoryInfo?
    private(set) var discoveredURLs: [URL] = []

    init(repository: GitRepositoryInfo?) {
        self.repository = repository
    }

    func discover(at url: URL) throws -> GitRepositoryInfo {
        discoveredURLs.append(url.standardizedFileURL)
        guard let repository else { throw CocoaError(.fileNoSuchFile) }
        return repository
    }
}

private final class BuiltInCommandsTestWatcher: RepositoryWatching {
    func cancel() {}
}

private actor BuiltInCommandsTestRemoteService: SSHRemoteRepositoryServicing {
    nonisolated let mirrorRoot: URL
    private(set) var synchronizationCount = 0

    init(mirrorRoot: URL) {
        self.mirrorRoot = mirrorRoot
    }

    nonisolated func parseSource(_ specification: String) throws -> SSHRemoteRepositorySource {
        try SSHRemoteRepositorySource(specification: specification)
    }

    nonisolated func mirrorPath(for source: SSHRemoteRepositorySource) -> URL {
        mirrorRoot
    }

    func synchronize(
        _ source: SSHRemoteRepositorySource
    ) async throws -> SSHRemoteRepositorySnapshot {
        synchronizationCount += 1
        return SSHRemoteRepositorySnapshot(
            source: source,
            rootURL: mirrorRoot,
            gitDirectoryURL: mirrorRoot.appendingPathComponent(".git", isDirectory: true),
            worktrees: [SSHRemoteWorktreeSnapshot(
                name: "main",
                localURL: mirrorRoot,
                remotePath: source.remotePath,
                isMain: true,
                head: "0123456789abcdef"
            )]
        )
    }
}
