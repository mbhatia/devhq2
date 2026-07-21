import Foundation
import XCTest
@testable import DevHQ

final class WorkspacePreviewTests: XCTestCase {
    @MainActor
    func testCleanPreviewIsReplacedAtItsTabPosition() throws {
        let root = try makeWorkspace(files: [
            "Persistent.swift": "let persistent = true",
            "First.swift": "let first = true",
            "Second.swift": "let second = true"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(root)
        model.openFile(root.appendingPathComponent("Persistent.swift"))
        let persistentID = try XCTUnwrap(model.selectedDocumentID)

        model.open(try leaf("First.swift", in: model.fileTree.roots))
        let firstPreviewID = try XCTUnwrap(model.selectedDocumentID)
        XCTAssertTrue(model.selectedDocument?.isEphemeral == true)

        model.open(try leaf("Second.swift", in: model.fileTree.roots))

        XCTAssertEqual(model.documents.count, 2)
        XCTAssertEqual(model.tabs.map(\.id).first, persistentID)
        XCTAssertNotEqual(model.selectedDocumentID, firstPreviewID)
        XCTAssertEqual(model.selectedDocument?.url.lastPathComponent, "Second.swift")
        XCTAssertTrue(model.selectedDocument?.isEphemeral == true)
    }

    @MainActor
    func testEditAndPersistentOpenPromotePreview() throws {
        let root = try makeWorkspace(files: [
            "Edited.swift": "let edited = false",
            "Opened.swift": "let opened = false"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(root)

        model.open(try leaf("Edited.swift", in: model.fileTree.roots))
        model.selectedDocument?.text = "let edited = true"
        XCTAssertFalse(model.selectedDocument?.isEphemeral == true)
        XCTAssertTrue(model.selectedDocument?.isDirty == true)

        model.open(try leaf("Opened.swift", in: model.fileTree.roots))
        XCTAssertTrue(model.selectedDocument?.isEphemeral == true)
        model.openPersistently(try leaf("Opened.swift", in: model.fileTree.roots))
        XCTAssertFalse(model.selectedDocument?.isEphemeral == true)
        XCTAssertEqual(model.documents.count, 2)
    }

    @MainActor
    func testDirtyPreviewIsPreservedWhenAnotherPreviewOpens() throws {
        let root = try makeWorkspace(files: [
            "Dirty.swift": "before",
            "Next.swift": "next"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(root)
        model.open(try leaf("Dirty.swift", in: model.fileTree.roots))
        model.selectedDocument?.text = "after"

        model.open(try leaf("Next.swift", in: model.fileTree.roots))

        XCTAssertEqual(model.documents.map { $0.url.lastPathComponent }, ["Dirty.swift", "Next.swift"])
        XCTAssertEqual(model.documents.first?.text, "after")
        XCTAssertTrue(model.documents.first?.isDirty == true)
    }

    @MainActor
    func testCleanPreviewIsExcludedFromPersistedWorkspaceState() throws {
        let root = try makeWorkspace(files: [
            "Persistent.swift": "persistent",
            "Preview.swift": "preview"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PreviewWorkspaceStateStore()
        let model = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)
        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: root)
        model.openFile(root.appendingPathComponent("Persistent.swift"))
        model.open(try leaf("Preview.swift", in: model.fileTree.roots))

        model.saveCurrentWorkspaceState()

        XCTAssertEqual(store.state?.tabs.map(\.path), ["Persistent.swift"])
        XCTAssertEqual(store.state?.selectedTabPath, "Persistent.swift")
    }

    private func leaf(_ id: String, in nodes: [FileNode]) throws -> FileNode {
        try XCTUnwrap(nodes.first(where: { $0.id == id }))
    }

    private func makeWorkspace(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            try contents.write(
                to: root.appendingPathComponent(path),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }
}

private final class PreviewWorkspaceStateStore: WorkspaceStatePersisting {
    var state: PersistedWorkspaceState?

    func loadRepositories() throws -> [PersistedRepositoryState] { [] }
    func saveRepositories(_ repositories: [PersistedRepositoryState]) throws {}
    func loadWorkspaceState(
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws -> PersistedWorkspaceState? { state }
    func saveWorkspaceState(
        _ state: PersistedWorkspaceState,
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws {
        self.state = state
    }
}
