import Foundation
import XCTest
@testable import DevHQ
import CodeEditLanguages

final class DevHQTests: XCTestCase {
    func testSwiftTreeSitterHighlightsCode() {
        let text = "struct Example { let value = 42 }"
        XCTAssertNotNil(CodeLanguage.swift.language, "Swift parser language should load")
        XCTAssertNotNil(CodeLanguage.swift.queryURL, "Swift highlight query resource should load")
        let tokens = TreeSitterHighlighter.tokens(in: text, language: .swift)

        XCTAssertFalse(tokens.isEmpty)
        XCTAssertTrue(tokens.contains { $0.name.hasPrefix("keyword") })
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
