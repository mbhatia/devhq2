import Foundation
import XCTest
@testable import DevHQ
import CodeEditLanguages

final class DevHQTests: XCTestCase {
    @MainActor
    func testTreeStartsWithOnlyFirstLevelExpandedAndCanToggle() {
        let nestedBranch = TreeNode(id: "nested", value: 2, children: [
            TreeNode(id: "leaf", value: 3, children: nil)
        ])
        let rootBranch = TreeNode(id: "root", value: 1, children: [nestedBranch])
        let model = TreeModel(roots: [rootBranch])

        XCTAssertTrue(model.isExpanded(rootBranch))
        XCTAssertFalse(model.isExpanded(nestedBranch))

        model.toggle(nestedBranch)
        XCTAssertTrue(model.isExpanded(nestedBranch))
        model.toggle(rootBranch)
        XCTAssertFalse(model.isExpanded(rootBranch))

        XCTAssertTrue(model.reveal("leaf"))
        XCTAssertTrue(model.isExpanded(rootBranch))
        XCTAssertTrue(model.isExpanded(nestedBranch))
    }

    @MainActor
    func testActiveDocumentSelectsAndRevealsItsTreeNode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sources = directory.appendingPathComponent("Sources", isDirectory: true)
        let feature = sources.appendingPathComponent("Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = feature.appendingPathComponent("Selected.swift")
        try "let selected = true".write(to: file, atomically: true, encoding: .utf8)

        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(directory)
        XCTAssertFalse(model.fileTree.expandedIDs.contains("Sources/Feature"))

        model.openFile(file)

        XCTAssertEqual(model.selectedFileNodeID, "Sources/Feature/Selected.swift")
        XCTAssertTrue(
            model.fileTree.expandedIDs.contains("Sources"),
            "Expanded IDs: \(model.fileTree.expandedIDs)"
        )
        XCTAssertTrue(
            model.fileTree.expandedIDs.contains("Sources/Feature"),
            "Expanded IDs: \(model.fileTree.expandedIDs)"
        )
    }

    func testSourceEditorFeaturesAreEnabled() {
        let configuration = SourceEditorView.configuration(isDark: false)

        XCTAssertTrue(configuration.peripherals.showGutter)
        XCTAssertTrue(configuration.peripherals.showMinimap)
        XCTAssertTrue(configuration.peripherals.showFoldingRibbon)
    }

    @MainActor
    func testSwiftSyntaxHighlightingProducesKeywordCapture() {
        let highlights = CorrectedTreeSitterHighlightProvider.highlights(
            in: "struct Example { let value = 42 }",
            language: .swift
        )

        XCTAssertTrue(highlights.contains { $0.capture == .keyword })
    }

    @MainActor
    func testOpenEditAndSaveFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("Sample.swift")
        try "let oldValue = 1".write(to: file, atomically: true, encoding: .utf8)

        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(directory)
        model.openFile(file)
        model.selectedDocument?.text = "let newValue = 2"
        model.saveSelected()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let newValue = 2")
    }
}
