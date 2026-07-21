import Darwin
import Foundation
import XCTest
@testable import DevHQ

final class TerminalSessionTests: XCTestCase {
    func testOSC8HyperlinksSurviveSGRAndEndExplicitly() {
        var parser = TerminalParser(columns: 20, rows: 2)
        parser.feed(Array("\u{1B}]8;id=docs;https://example.com/docs\u{1B}\\A\u{1B}[0mB\u{1B}]8;;\u{7}C".utf8))

        let cells = parser.snapshot().cells[0]
        XCTAssertEqual(cells[0].text, "A")
        XCTAssertEqual(cells[0].hyperlink, "https://example.com/docs")
        XCTAssertEqual(cells[1].hyperlink, "https://example.com/docs")
        XCTAssertNil(cells[2].hyperlink)
    }

    func testOSC9AndOSC52ProduceStrictBoundedEffects() {
        var parser = TerminalParser(columns: 20, rows: 2)
        parser.feed(Array("\u{1B}]2;Build\u{7}\u{1B}]9;Finished\u{7}\u{1B}]52;c;Y2xpcGJvYXJk\u{7}".utf8))

        XCTAssertEqual(parser.takeEffects(), [
            .notification(title: "Build", body: "Finished"),
            .clipboardWrite("clipboard")
        ])

        parser.feed(Array("\u{1B}]52;c;?\u{7}\u{1B}]52;c;not-base64!\u{7}".utf8))
        XCTAssertTrue(parser.takeEffects().isEmpty)

        parser.feed(Array("\u{1B}]52;c;\u{7}".utf8))
        XCTAssertEqual(parser.takeEffects(), [.clipboardWrite("")])

        let oversized = "\u{1B}]9;" + String(repeating: "x", count: 1024 * 1024 + 1) + "\u{7}"
        parser.feed(oversized.utf8)
        XCTAssertTrue(parser.takeEffects().isEmpty)
    }

    func testOSCEffectsCoalesceAndSequencesCanSpanChunks() {
        var parser = TerminalParser(columns: 20, rows: 2)
        for index in 0..<100 {
            parser.feed(Array("\u{1B}]9;message-\(index)\u{7}".utf8))
        }
        parser.feed(Array("\u{1B}]52;c;Zmlyc3Q=\u{7}\u{1B}]52;c;c2Vjb25k\u{7}".utf8))
        XCTAssertEqual(parser.takeEffects(), [
            .notification(title: "DevHQ Terminal", body: "message-99"),
            .clipboardWrite("second")
        ])

        parser.feed(Array("\u{1B}]9;split".utf8) + [0x1b])
        XCTAssertTrue(parser.takeEffects().isEmpty)
        parser.feed([0x5c])
        XCTAssertEqual(parser.takeEffects(), [
            .notification(title: "DevHQ Terminal", body: "split")
        ])
    }

    func testC1OSCAndSTDoNotBreakUTF8ContinuationBytes() {
        var parser = TerminalParser(columns: 20, rows: 2)
        parser.feed([0x9d] + Array("9;c1-notification".utf8))
        XCTAssertTrue(parser.takeEffects().isEmpty)
        parser.feed([0x9c])
        XCTAssertEqual(parser.takeEffects(), [
            .notification(title: "DevHQ Terminal", body: "c1-notification")
        ])

        parser.feed(Array("Ý".utf8))
        XCTAssertEqual(parser.snapshot().cells[0][0].text, "Ý")
    }

    @MainActor
    func testHostEffectsDrainWhileInactiveAndCmdClickOpeningIsTestable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = RecordingTerminalHostServices()
        let session = try TerminalSession(rootURL: root, shell: "/bin/sh", hostServices: host)
        defer { session.close() }
        session.setActive(false)

        session.send(text: "printf '\\033]9;Discarded\\007\\033]9;Inactive\\007\\033]52;c;ZnJvbS10ZXJtaW5hbA==\\007\\033]8;;https://example.com\\033\\\\Z\\033]8;;\\007'; sleep 1\n")

        let deadline = Date().addingTimeInterval(3)
        while (host.notifications.isEmpty || host.clipboardWrites.isEmpty), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        XCTAssertEqual(host.notifications.map(\.body), ["Inactive"])
        XCTAssertEqual(host.clipboardWrites, ["from-terminal"])

        session.setActive(true)
        var opened = false
        for row in 0..<session.snapshot.rows where !opened {
            for column in 0..<session.snapshot.columns where !opened {
                opened = session.openHyperlink(at: (column, row))
            }
        }
        XCTAssertTrue(opened)
        XCTAssertEqual(host.openedURLs, [URL(string: "https://example.com")!])
    }

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
    func testDirectCommandUsesArgumentsAndRequestedWorkingDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let session = try TerminalSession(
            rootURL: root,
            workingDirectory: workingDirectory,
            command: [
                "/bin/sh", "-c",
                "test \"$(pwd -P)\" = \"$(cd \"$1\" && pwd -P)\" || exit 4; "
                    + "printf 'direct-argv:%s' \"$2\"; exit 6",
                "launcher", workingDirectory.path, "argument"
            ],
            shell: "/does/not/exist"
        )
        defer { session.close() }

        let deadline = Date().addingTimeInterval(3)
        while session.exitStatus == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        XCTAssertEqual(session.currentDirectory, workingDirectory)
        XCTAssertEqual(session.exitStatus, 6)
        let output = session.snapshot.cells.flatMap { $0 }.map(\.text).joined()
        XCTAssertTrue(output.contains("direct-argv:argument"))
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

@MainActor
private final class RecordingTerminalHostServices: TerminalHostServices {
    struct Notification: Equatable {
        let title: String
        let body: String
    }

    private(set) var openedURLs: [URL] = []
    private(set) var notifications: [Notification] = []
    private(set) var clipboardWrites: [String] = []

    func open(url: URL) { openedURLs.append(url) }

    func showNotification(title: String, body: String) {
        notifications.append(Notification(title: title, body: body))
    }

    func writeClipboard(_ string: String) { clipboardWrites.append(string) }
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
