import Foundation
import XCTest
@testable import DevHQ

final class WorkspaceCommandOperationsTests: XCTestCase {
    @MainActor
    func testCreateFileRefreshesTreeOpensFileAndPreservesUnrelatedExpansion() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
        let other = workspace.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(workspace)
        model.fileTree.restoreExpandedIDs([])
        let target = sources.appendingPathComponent("New.swift")

        let document = try model.createFile(at: target)

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "")
        XCTAssertEqual(document.url, target.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(model.selectedDocumentID, document.id)
        XCTAssertEqual(model.selectedFileNodeID, "Sources/New.swift")
        XCTAssertTrue(model.fileTree.expandedIDs.contains("Sources"))
        XCTAssertFalse(model.fileTree.expandedIDs.contains("Other"))
        XCTAssertNotNil(fileNode(id: "Sources/New.swift", in: model.fileTree.roots))
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testCreateDirectoryRefreshesTreeWithoutResettingExpansion() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
        let other = workspace.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(workspace)
        model.fileTree.restoreExpandedIDs(["Other"])
        let target = sources.appendingPathComponent("Generated", isDirectory: true)

        try model.createDirectory(at: target)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(model.fileTree.expandedIDs, ["Other"])
        XCTAssertTrue(fileNode(id: "Sources/Generated", in: model.fileTree.roots)?.isDirectory == true)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testCreationRejectsNoWorkspaceOutsideExistingAndMissingParentTargets() throws {
        let model = WorkspaceModel(arguments: ["DevHQ"])
        let arbitraryTarget = URL(fileURLWithPath: "/tmp/New.swift")
        XCTAssertThrowsError(try model.createFile(at: arbitraryTarget)) { error in
            XCTAssertEqual(error as? WorkspaceCommandOperationError, .noWorkspace)
        }
        XCTAssertNotNil(model.errorMessage)

        let workspace = try makeWorkspace()
        let outside = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }
        model.openWorkspace(workspace)

        let outsideTarget = outside.appendingPathComponent("Outside.swift")
        XCTAssertThrowsError(try model.createFile(at: outsideTarget)) { error in
            XCTAssertEqual(
                error as? WorkspaceCommandOperationError,
                .outsideWorkspace(outsideTarget.standardizedFileURL.resolvingSymlinksInPath())
            )
        }

        let existing = workspace.appendingPathComponent("Existing.swift")
        try "keep".write(to: existing, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try model.createFile(at: existing)) { error in
            XCTAssertEqual(
                error as? WorkspaceCommandOperationError,
                .targetExists(existing.standardizedFileURL.resolvingSymlinksInPath())
            )
        }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")

        let missingParent = workspace.appendingPathComponent("Missing", isDirectory: true)
        let nested = missingParent.appendingPathComponent("Nested", isDirectory: true)
        XCTAssertThrowsError(try model.createDirectory(at: nested)) { error in
            XCTAssertEqual(
                error as? WorkspaceCommandOperationError,
                .parentDirectoryMissing(missingParent)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
    }

    @MainActor
    func testCloseSelectedDiscardsDirtyTextAndSelectsRightNeighbor() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let first = workspace.appendingPathComponent("First.swift")
        let second = workspace.appendingPathComponent("Second.swift")
        let third = workspace.appendingPathComponent("Third.swift")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        try "third".write(to: third, atomically: true, encoding: .utf8)

        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(workspace)
        model.openFile(first)
        model.openFile(second)
        let dirtyDocument = try XCTUnwrap(model.selectedDocument)
        model.openFile(third)
        model.select(dirtyDocument)
        dirtyDocument.text = "unsaved second"

        model.closeSelected()

        XCTAssertEqual(model.documents.map { $0.url.lastPathComponent }, ["First.swift", "Third.swift"])
        XCTAssertEqual(model.selectedDocument?.url.lastPathComponent, "Third.swift")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
        XCTAssertFalse(model.documents.contains { $0.id == dirtyDocument.id })

        model.closeSelected()
        model.closeSelected()
        model.closeSelected()
        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertNil(model.selectedDocumentID)
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileNode(id: String, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children, let match = fileNode(id: id, in: children) {
                return match
            }
        }
        return nil
    }
}
