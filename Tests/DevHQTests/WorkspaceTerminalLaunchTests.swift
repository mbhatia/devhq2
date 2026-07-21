import Foundation
import XCTest
@testable import DevHQ

final class WorkspaceTerminalLaunchTests: XCTestCase {
    @MainActor
    func testNewTerminalRejectsMissingOrNondirectoryWorkingDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-directory")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(root)

        for invalidURL in [file, missing] {
            XCTAssertThrowsError(try model.newTerminal(workingDirectory: invalidURL)) { error in
                XCTAssertEqual(
                    error as? WorkspaceCommandOperationError,
                    .invalidTerminalWorkingDirectory(
                        invalidURL.standardizedFileURL.resolvingSymlinksInPath()
                    )
                )
            }
        }
        XCTAssertTrue(model.tabs.isEmpty)
    }

    @MainActor
    func testOptionBearingTerminalLaunchAppendsToMixedTabs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        let file = root.appendingPathComponent("File.swift")
        try "let value = 1".write(to: file, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(root)
        model.openFile(file)
        let documentID = try XCTUnwrap(model.selectedDocument?.id)

        let terminal = try model.newTerminal(
            workingDirectory: workingDirectory,
            command: ["/bin/sh", "-c", "sleep 1"]
        )
        defer { model.closeAllTerminals() }

        XCTAssertEqual(terminal.rootURL, root.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(
            terminal.currentDirectory,
            workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(model.tabs.map(\.id), [documentID, terminal.id])
        XCTAssertEqual(model.selectedTerminal?.id, terminal.id)
        XCTAssertEqual(model.documents.map(\.id), [documentID])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
