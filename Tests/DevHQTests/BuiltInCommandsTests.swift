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
            "worktree:add-repo", "file:new", "file:new-dir", "file:close"
        ])
        XCTAssertEqual(manager.commandsByID["worktree:add-repo"]?.title, "worktree: add repo")
        XCTAssertEqual(manager.commandsByID["file:new"]?.title, "file: new")
        XCTAssertEqual(manager.commandsByID["file:new-dir"]?.title, "file: new dir")
        XCTAssertEqual(manager.commandsByID["file:close"]?.title, "file: close")
        XCTAssertEqual(
            manager.commandsByID["worktree:add-repo"]?.viewKinds,
            Set(CommandViewKind.allCases)
        )
        XCTAssertEqual(manager.commandsByID["file:new"]?.viewKinds, [.file, .document])
        XCTAssertEqual(manager.commandsByID["file:new-dir"]?.viewKinds, [.file, .document])
        XCTAssertEqual(manager.commandsByID["file:close"]?.viewKinds, [.document])

        for view in CommandViewKind.allCases {
            XCTAssertEqual(
                try manager.commands(in: CommandContext(view: view)).map(\.id),
                ["worktree:add-repo"]
            )
        }

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.openWorkspace(root)
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .file)).map(\.id),
            ["file:new", "file:new-dir", "worktree:add-repo"]
        )
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .document)).map(\.id),
            ["file:new", "file:new-dir", "worktree:add-repo"]
        )

        let existingFile = root.appendingPathComponent("Open.swift")
        try "let open = true".write(to: existingFile, atomically: true, encoding: .utf8)
        workspace.openFile(existingFile)
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .document)).map(\.id),
            ["file:close", "file:new", "file:new-dir", "worktree:add-repo"]
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
    func testCancelledPickersHaveNoModelSideEffects() throws {
        let workspaceRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(workspaceRoot)
        let explorer = makeExplorer()
        var repositoryPickerCalls = 0
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
        try manager.execute(id: "file:new", in: CommandContext(view: .file))
        try manager.execute(id: "file:new-dir", in: CommandContext(view: .document))

        XCTAssertEqual(repositoryPickerCalls, 1)
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
        discoverer: any GitWorktreeDiscovering = BuiltInCommandsTestDiscoverer(repository: nil)
    ) -> WorktreeExplorerModel {
        WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { _, _ in },
            watcherFactory: { _, _ in BuiltInCommandsTestWatcher() },
            eventDelivery: { $0() }
        )
    }

    private func cancellingPickers() -> BuiltInCommandPickers {
        BuiltInCommandPickers(
            repositoryURL: { nil },
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
