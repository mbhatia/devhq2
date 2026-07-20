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
}
