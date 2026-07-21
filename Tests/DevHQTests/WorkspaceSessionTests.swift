import Foundation
import XCTest
@testable import DevHQ

final class WorkspaceSessionTests: XCTestCase {
    @MainActor
    func testSwitchingWorkspacesRestoresTabsSelectionAndUnsavedText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstWorkspace = root.appendingPathComponent("first", isDirectory: true)
        let secondWorkspace = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondWorkspace, withIntermediateDirectories: true)
        let firstSources = firstWorkspace.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: firstSources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstA = firstWorkspace.appendingPathComponent("FirstA.swift")
        let firstB = firstSources.appendingPathComponent("FirstB.swift")
        let secondA = secondWorkspace.appendingPathComponent("SecondA.swift")
        try "let firstA = 1".write(to: firstA, atomically: true, encoding: .utf8)
        try "let firstB = 2".write(to: firstB, atomically: true, encoding: .utf8)
        try "let secondA = 3".write(to: secondA, atomically: true, encoding: .utf8)

        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(firstWorkspace)
        model.openFile(firstA)
        model.openFile(firstB)
        model.selectedDocument?.text = "let firstB = 200"
        let selectedFirstDocumentID = try XCTUnwrap(model.selectedDocumentID)

        model.openWorkspace(secondWorkspace)
        model.openFile(secondA)
        model.selectedDocument?.text = "let secondA = 300"
        let selectedSecondDocumentID = try XCTUnwrap(model.selectedDocumentID)

        model.openWorkspace(firstWorkspace)

        XCTAssertEqual(model.documents.map(\.url), [firstA, firstB])
        XCTAssertEqual(model.selectedDocumentID, selectedFirstDocumentID)
        XCTAssertEqual(model.selectedDocument?.url, firstB)
        XCTAssertEqual(model.selectedDocument?.text, "let firstB = 200")
        XCTAssertTrue(model.selectedDocument?.isDirty == true)
        XCTAssertEqual(model.selectedFileNodeID, "Sources/Feature/FirstB.swift")
        XCTAssertTrue(model.fileTree.expandedIDs.contains("Sources/Feature"))

        model.openWorkspace(secondWorkspace)

        XCTAssertEqual(model.documents.map(\.url), [secondA])
        XCTAssertEqual(model.selectedDocumentID, selectedSecondDocumentID)
        XCTAssertEqual(model.selectedDocument?.url, secondA)
        XCTAssertEqual(model.selectedDocument?.text, "let secondA = 300")
        XCTAssertTrue(model.selectedDocument?.isDirty == true)
        XCTAssertEqual(model.selectedFileNodeID, "SecondA.swift")
    }

    @MainActor
    func testReopeningSameWorkspaceKeepsCurrentTabsAndSelection() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let file = workspace.appendingPathComponent("Current.swift")
        try "let current = 1".write(to: file, atomically: true, encoding: .utf8)

        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(workspace)
        model.openFile(file)
        model.selectedDocument?.text = "let current = 2"
        let selectedDocumentID = try XCTUnwrap(model.selectedDocumentID)

        model.openWorkspace(workspace.appendingPathComponent("../\(workspace.lastPathComponent)"))

        XCTAssertEqual(model.documents.count, 1)
        XCTAssertEqual(model.selectedDocumentID, selectedDocumentID)
        XCTAssertEqual(model.selectedDocument?.text, "let current = 2")
        XCTAssertTrue(model.selectedDocument?.isDirty == true)
        XCTAssertEqual(model.selectedFileNodeID, "Current.swift")
    }

    @MainActor
    func testPersistentSwitchSavesAndNewModelRestoresExactWorkspaceState() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        let feature = first.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let clean = feature.appendingPathComponent("Clean.swift")
        let dirty = feature.appendingPathComponent("Dirty.swift")
        let secondFile = second.appendingPathComponent("Second.swift")
        try "let clean = 1".write(to: clean, atomically: true, encoding: .utf8)
        try "let dirty = 1".write(to: dirty, atomically: true, encoding: .utf8)
        try "let second = 1".write(to: secondFile, atomically: true, encoding: .utf8)

        let store = InMemoryWorkspaceStateStore()
        let model = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)
        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: first)
        model.openFile(clean)
        model.openFile(dirty)
        model.selectedDocument?.text = "let dirty = 2"
        model.fileTree.restoreExpandedIDs(["Sources"])

        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "feature", url: second)

        let saved = try XCTUnwrap(store.workspaceState(repository: "repo", worktree: "main"))
        XCTAssertEqual(saved.expandedFileNodeIDs, ["Sources"])
        XCTAssertEqual(saved.tabs.map(\.path), [
            "Sources/Feature/Clean.swift",
            "Sources/Feature/Dirty.swift"
        ])
        XCTAssertNil(saved.tabs[0].unsavedText)
        XCTAssertNil(saved.tabs[0].savedText)
        XCTAssertEqual(saved.tabs[1].unsavedText, "let dirty = 2")
        XCTAssertEqual(saved.tabs[1].savedText, "let dirty = 1")
        XCTAssertEqual(saved.selectedTabPath, "Sources/Feature/Dirty.swift")

        try "let clean = 3".write(to: clean, atomically: true, encoding: .utf8)
        let restored = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)
        restored.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: first)

        XCTAssertEqual(restored.documents.map(\.url), [clean, dirty])
        XCTAssertEqual(restored.documents.map(\.text), ["let clean = 3", "let dirty = 2"])
        XCTAssertFalse(restored.documents[0].isDirty)
        XCTAssertEqual(restored.documents[1].savedText, "let dirty = 1")
        XCTAssertTrue(restored.documents[1].isDirty)
        XCTAssertEqual(restored.selectedDocument?.url, dirty)
        XCTAssertEqual(restored.fileTree.expandedIDs, ["Sources"])
        XCTAssertFalse(
            restored.fileTree.expandedIDs.contains("Sources/Feature"),
            "Restoring the selected tab must not reveal it in the file tree"
        )
    }

    @MainActor
    func testRestoreSkipsMissingCleanAndOutsideTabsButKeepsMissingDirtyTab() throws {
        let workspace = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let present = workspace.appendingPathComponent("Present.swift")
        try "let present = true".write(to: present, atomically: true, encoding: .utf8)

        let store = InMemoryWorkspaceStateStore()
        store.setWorkspaceState(
            PersistedWorkspaceState(
                expandedFileNodeIDs: ["stale", "Present.swift"],
                tabs: [
                    PersistedEditorTabState(
                        path: "MissingClean.swift",
                        unsavedText: nil,
                        savedText: nil
                    ),
                    PersistedEditorTabState(
                        path: "DeletedDirty.swift",
                        unsavedText: "unsaved",
                        savedText: "on disk"
                    ),
                    PersistedEditorTabState(
                        path: "../Outside.swift",
                        unsavedText: "outside",
                        savedText: "outside baseline"
                    ),
                    PersistedEditorTabState(
                        path: present.path,
                        unsavedText: "absolute",
                        savedText: "absolute baseline"
                    ),
                    PersistedEditorTabState(
                        path: "Present.swift",
                        unsavedText: nil,
                        savedText: nil
                    )
                ],
                selectedTabPath: "DeletedDirty.swift"
            ),
            repository: "repo",
            worktree: "main"
        )

        let model = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)
        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: workspace)

        XCTAssertEqual(model.documents.map { $0.url.lastPathComponent }, [
            "DeletedDirty.swift",
            "Present.swift"
        ])
        XCTAssertEqual(model.documents[0].text, "unsaved")
        XCTAssertEqual(model.documents[0].savedText, "on disk")
        XCTAssertTrue(model.documents[0].isDirty)
        XCTAssertEqual(model.selectedDocument?.url.lastPathComponent, "DeletedDirty.swift")
        XCTAssertEqual(model.fileTree.expandedIDs, [])
    }

    @MainActor
    func testSaveCurrentWorkspaceStateSupportsApplicationTermination() throws {
        let workspace = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("Current.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let store = InMemoryWorkspaceStateStore()
        let model = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)
        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: workspace)
        model.openFile(file)
        model.selectedDocument?.text = "edited"

        model.saveCurrentWorkspaceState()

        XCTAssertEqual(store.workspaceSaves.count, 1)
        let saved = try XCTUnwrap(store.workspaceState(repository: "repo", worktree: "main"))
        XCTAssertEqual(saved.tabs.first?.path, "Current.swift")
        XCTAssertEqual(saved.tabs.first?.unsavedText, "edited")
        XCTAssertEqual(saved.tabs.first?.savedText, "original")
    }

    @MainActor
    func testUpdatingCurrentWorktreeBranchIdentityPreservesUIAndSavesNewKey() throws {
        let workspace = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("Current.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let store = InMemoryWorkspaceStateStore()
        let model = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)
        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "old", url: workspace)
        model.openFile(file)
        model.selectedDocument?.text = "edited"
        model.fileTree.restoreExpandedIDs(["Sources"])
        let documentID = try XCTUnwrap(model.selectedDocumentID)

        model.updateCurrentWorktreeIdentity(
            canonicalRepositoryName: "repo",
            worktreeName: "feature/new-name",
            url: workspace
        )

        XCTAssertEqual(model.documents.map(\.id), [documentID])
        XCTAssertEqual(model.selectedDocumentID, documentID)
        XCTAssertEqual(model.selectedDocument?.text, "edited")
        XCTAssertTrue(model.selectedDocument?.isDirty == true)
        XCTAssertEqual(model.fileTree.expandedIDs, ["Sources"])
        XCTAssertNil(store.workspaceState(repository: "repo", worktree: "old"))
        let saved = try XCTUnwrap(
            store.workspaceState(repository: "repo", worktree: "feature/new-name")
        )
        XCTAssertEqual(saved.expandedFileNodeIDs, ["Sources"])
        XCTAssertEqual(saved.tabs.first?.path, "Sources/Current.swift")
        XCTAssertEqual(saved.tabs.first?.unsavedText, "edited")
        XCTAssertEqual(saved.tabs.first?.savedText, "original")
        XCTAssertEqual(saved.selectedTabPath, "Sources/Current.swift")
        XCTAssertEqual(store.workspaceSaves.count, 1)
    }

    @MainActor
    func testUpdatingWorktreeIdentityIsNoOpUnlessRepositoryURLAndBranchChangeMatch() throws {
        let workspace = temporaryDirectory()
        let otherWorkspace = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: otherWorkspace)
        }
        let store = InMemoryWorkspaceStateStore()
        let model = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)
        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: workspace)

        model.updateCurrentWorktreeIdentity(
            canonicalRepositoryName: "other",
            worktreeName: "renamed",
            url: workspace
        )
        model.updateCurrentWorktreeIdentity(
            canonicalRepositoryName: "repo",
            worktreeName: "renamed",
            url: otherWorkspace
        )
        model.updateCurrentWorktreeIdentity(
            canonicalRepositoryName: "repo",
            worktreeName: "main",
            url: workspace
        )

        XCTAssertTrue(store.workspaceSaves.isEmpty)
    }

    @MainActor
    func testDirectWorkspaceOpenSavesPersistentWorktreeAndReturnsToInMemoryBehavior() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistent = root.appendingPathComponent("persistent", isDirectory: true)
        let arbitrary = root.appendingPathComponent("arbitrary", isDirectory: true)
        try FileManager.default.createDirectory(at: persistent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: arbitrary, withIntermediateDirectories: true)

        let store = InMemoryWorkspaceStateStore()
        let model = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)
        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: persistent)

        model.openWorkspace(arbitrary)
        XCTAssertEqual(store.workspaceSaves.count, 1)

        model.openWorkspace(persistent)
        model.openWorkspace(arbitrary)
        XCTAssertEqual(
            store.workspaceSaves.count,
            1,
            "Arbitrary folder navigation must clear the persistent worktree identity"
        )
    }

    @MainActor
    func testPersistenceFailuresPublishErrorsButStillOpenWorkspace() throws {
        let first = temporaryDirectory()
        let second = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let store = InMemoryWorkspaceStateStore()
        store.loadError = TestPersistenceError.failed
        let model = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)

        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: first)

        XCTAssertEqual(model.rootURL, first.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertTrue(model.errorMessage?.contains("Could not load workspace state") == true)

        store.loadError = nil
        store.saveError = TestPersistenceError.failed
        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "other", url: second)

        XCTAssertEqual(model.rootURL, second.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertTrue(model.errorMessage?.contains("Could not save workspace state") == true)
    }

    @MainActor
    func testUnsavedChangesQueryFindsDirtyDocumentInActiveWorkspace() throws {
        let workspace = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("Current.swift")
        try "saved".write(to: file, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(workspace)
        model.openFile(file)

        XCTAssertFalse(model.hasUnsavedChanges(inWorkspaceAt: workspace))

        model.selectedDocument?.text = "unsaved"

        let equivalentURL = workspace.appendingPathComponent("..")
            .appendingPathComponent(workspace.lastPathComponent)
        XCTAssertTrue(model.hasUnsavedChanges(inWorkspaceAt: equivalentURL))
    }

    @MainActor
    func testUnsavedChangesQueryFindsDirtyDocumentInCachedWorkspaceOnly() throws {
        let first = temporaryDirectory()
        let second = temporaryDirectory()
        let unrelated = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
            try? FileManager.default.removeItem(at: unrelated)
        }
        let firstFile = first.appendingPathComponent("First.swift")
        let secondFile = second.appendingPathComponent("Second.swift")
        try "first saved".write(to: firstFile, atomically: true, encoding: .utf8)
        try "second saved".write(to: secondFile, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(first)
        model.openFile(firstFile)
        model.selectedDocument?.text = "first unsaved"
        model.openWorkspace(second)
        model.openFile(secondFile)

        XCTAssertTrue(model.hasUnsavedChanges(inWorkspaceAt: first))
        XCTAssertFalse(model.hasUnsavedChanges(inWorkspaceAt: second))
        XCTAssertFalse(model.hasUnsavedChanges(inWorkspaceAt: unrelated))
    }

    @MainActor
    func testClosingActiveWorkspaceClearsVisibleAndPersistentIdentityState() throws {
        let workspace = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("Current.swift")
        try "let current = true".write(to: file, atomically: true, encoding: .utf8)
        let store = InMemoryWorkspaceStateStore()
        let model = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)
        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: workspace)
        model.openFile(file)

        model.closeWorkspace(at: workspace.appendingPathComponent("..")
            .appendingPathComponent(workspace.lastPathComponent))
        model.saveCurrentWorkspaceState()

        XCTAssertNil(model.rootURL)
        XCTAssertTrue(model.fileTree.roots.isEmpty)
        XCTAssertTrue(model.fileTree.expandedIDs.isEmpty)
        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.selectedDocumentID)
        XCTAssertNil(model.selectedTabID)
        XCTAssertTrue(store.workspaceSaves.isEmpty)
    }

    @MainActor
    func testClosingInactiveWorkspaceEvictsOnlyItsSession() throws {
        let first = temporaryDirectory()
        let second = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let firstFile = first.appendingPathComponent("First.swift")
        let secondFile = second.appendingPathComponent("Second.swift")
        try "first".write(to: firstFile, atomically: true, encoding: .utf8)
        try "second".write(to: secondFile, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(first)
        model.openFile(firstFile)
        model.openWorkspace(second)
        model.openFile(secondFile)
        let secondDocumentID = try XCTUnwrap(model.selectedDocumentID)

        model.closeWorkspace(at: first)

        XCTAssertEqual(model.rootURL, second.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(model.documents.map(\.url), [secondFile])
        XCTAssertEqual(model.selectedDocumentID, secondDocumentID)

        model.openWorkspace(first)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertTrue(model.documents.isEmpty)
    }

    @MainActor
    func testClosingWorkspacePreservesUnrelatedCachedSessions() throws {
        let first = temporaryDirectory()
        let second = temporaryDirectory()
        let third = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
            try? FileManager.default.removeItem(at: third)
        }
        let firstFile = first.appendingPathComponent("First.swift")
        let secondFile = second.appendingPathComponent("Second.swift")
        let thirdFile = third.appendingPathComponent("Third.swift")
        try "first".write(to: firstFile, atomically: true, encoding: .utf8)
        try "second".write(to: secondFile, atomically: true, encoding: .utf8)
        try "third".write(to: thirdFile, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(first)
        model.openFile(firstFile)
        model.openWorkspace(second)
        model.openFile(secondFile)
        model.openWorkspace(third)
        model.openFile(thirdFile)

        model.closeWorkspace(at: second)

        XCTAssertEqual(model.documents.map(\.url), [thirdFile])
        model.openWorkspace(first)
        XCTAssertEqual(model.documents.map(\.url), [firstFile])
        model.openWorkspace(third)
        XCTAssertEqual(model.documents.map(\.url), [thirdFile])
        model.openWorkspace(second)
        XCTAssertTrue(model.documents.isEmpty)
    }

    @MainActor
    func testClosingWorkspaceClosesTerminalSharedByActiveAndCachedState() throws {
        let first = temporaryDirectory()
        let second = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(first)
        let terminal = try model.newTerminal(shell: "/bin/sh")
        let processID = terminal.processID
        model.openWorkspace(second)
        model.openWorkspace(first)

        model.closeWorkspace(at: first)

        XCTAssertEqual(kill(processID, 0), -1)
        XCTAssertTrue(model.tabs.isEmpty)
        model.openWorkspace(first)
        XCTAssertTrue(model.tabs.isEmpty)
    }

    @MainActor
    func testExactExpansionRestoreKeepsOnlyCurrentBranches() {
        let nested = TreeNode(id: "nested", value: 2, children: [
            TreeNode(id: "leaf", value: 3, children: nil)
        ])
        let root = TreeNode(id: "root", value: 1, children: [nested])
        let model = TreeModel(roots: [root])

        model.restoreExpandedIDs(["nested", "leaf", "stale"])

        XCTAssertEqual(model.expandedIDs, ["nested"])
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum TestPersistenceError: Error {
    case failed
}

private final class InMemoryWorkspaceStateStore: WorkspaceStatePersisting {
    struct Key: Hashable {
        let repository: String
        let worktree: String
    }

    private(set) var workspaceStates: [Key: PersistedWorkspaceState] = [:]
    private(set) var workspaceSaves: [(Key, PersistedWorkspaceState)] = []
    var loadError: Error?
    var saveError: Error?

    func loadRepositories() throws -> [PersistedRepositoryState] { [] }

    func saveRepositories(_ repositories: [PersistedRepositoryState]) throws {}

    func loadWorkspaceState(
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws -> PersistedWorkspaceState? {
        if let loadError { throw loadError }
        return workspaceStates[Key(repository: canonicalRepositoryName, worktree: worktreeName)]
    }

    func saveWorkspaceState(
        _ state: PersistedWorkspaceState,
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws {
        if let saveError { throw saveError }
        let key = Key(repository: canonicalRepositoryName, worktree: worktreeName)
        workspaceStates[key] = state
        workspaceSaves.append((key, state))
    }

    func workspaceState(repository: String, worktree: String) -> PersistedWorkspaceState? {
        workspaceStates[Key(repository: repository, worktree: worktree)]
    }

    func setWorkspaceState(
        _ state: PersistedWorkspaceState,
        repository: String,
        worktree: String
    ) {
        workspaceStates[Key(repository: repository, worktree: worktree)] = state
    }
}
