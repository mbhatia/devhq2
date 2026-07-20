import Darwin
import Foundation
import XCTest
@testable import DevHQ

final class TerminalSessionTests: XCTestCase {
    @MainActor
    func testShellOutputInputTitleAndExitRemainVisible() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try TerminalSession(rootURL: root, shell: "/bin/sh")
        defer { session.close() }

        session.send(text: "printf '\\033]2;Fixture\\007hello\\n'; exit 7\n")

        let deadline = Date().addingTimeInterval(3)
        while session.exitStatus == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        XCTAssertEqual(session.title, "Fixture")
        XCTAssertEqual(session.exitStatus, 7)
        XCTAssertTrue(session.displayTitle.contains("exit 7"))
        XCTAssertTrue(session.snapshot.cells.flatMap { $0 }.map(\.text).joined().contains("hello"))
    }

    @MainActor
    func testMixedTabsSurviveWorktreeSwitchAndPersistenceContainsOnlyFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let file = first.appendingPathComponent("File.swift")
        try "let value = 1".write(to: file, atomically: true, encoding: .utf8)
        let store = TerminalTestWorkspaceStore()
        let model = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)

        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: first)
        model.openFile(file)
        let terminal = try model.newTerminal(shell: "/bin/sh")
        let pid = terminal.processID
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.selectedTerminal?.id, terminal.id)

        model.saveCurrentWorkspaceState()
        let saved = try XCTUnwrap(store.workspaceState(repository: "repo", worktree: "main"))
        XCTAssertEqual(saved.tabs.map { $0.path }, ["File.swift"])
        XCTAssertEqual(saved.selectedTabPath, "File.swift")

        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "feature", url: second)
        XCTAssertTrue(model.tabs.isEmpty)
        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: first)

        XCTAssertEqual(model.selectedTerminal?.id, terminal.id)
        XCTAssertEqual(model.selectedTerminal?.processID, pid)
        XCTAssertEqual(model.tabs.map { $0.id }, [model.documents[0].id, terminal.id])
        model.closeAllTerminals()
    }

    @MainActor
    func testClosingTerminalTerminatesOnlyItsProcess() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(root)
        let first = try model.newTerminal(shell: "/bin/sh")
        let second = try model.newTerminal(shell: "/bin/sh")
        let firstPID = first.processID
        let secondPID = second.processID

        model.close(first)

        XCTAssertEqual(kill(firstPID, 0), -1)
        XCTAssertEqual(kill(secondPID, 0), 0)
        XCTAssertEqual(model.terminalSessions.map(\.id), [second.id])
        model.closeAllTerminals()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class TerminalTestWorkspaceStore: WorkspaceStatePersisting {
    private var states: [String: PersistedWorkspaceState] = [:]

    func loadRepositories() throws -> [PersistedRepositoryState] { [] }
    func saveRepositories(_ repositories: [PersistedRepositoryState]) throws {}

    func loadWorkspaceState(
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws -> PersistedWorkspaceState? {
        states[canonicalRepositoryName + "\u{0}" + worktreeName]
    }

    func saveWorkspaceState(
        _ state: PersistedWorkspaceState,
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws {
        states[canonicalRepositoryName + "\u{0}" + worktreeName] = state
    }

    func workspaceState(repository: String, worktree: String) -> PersistedWorkspaceState? {
        states[repository + "\u{0}" + worktree]
    }
}
