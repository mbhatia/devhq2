import Foundation
import XCTest
@testable import DevHQ

final class WorkspaceTerminalLaunchTests: XCTestCase {
    @MainActor
    func testRemoteLoginShellUsesSSHAndQuotesTheRealWorktreePath() {
        let remotePath = "/srv/repos/a developer's checkout"
        let script = "cd \(shellQuote(remotePath)) && exec ${SHELL:-/bin/sh} -l"

        XCTAssertEqual(
            WorkspaceModel.remoteLoginShellCommandArguments(
                server: "build@example.com",
                remoteWorkingDirectory: remotePath
            ),
            [
                "ssh",
                "-At",
                "build@example.com",
                "/bin/sh -c \(shellQuote(script))"
            ]
        )
    }

    @MainActor
    func testRemoteExplicitCommandPreservesArgvWithoutLocalExpansion() {
        let script = "cd '/srv/a worktree' && exec "
            + "'/usr/bin/printf' '%s' '$HOME'\\''s value'"
        let arguments = WorkspaceModel.remoteCommandArguments(
            server: "build",
            remoteWorkingDirectory: "/srv/a worktree",
            command: ["/usr/bin/printf", "%s", "$HOME's value"]
        )
        XCTAssertEqual(arguments, ["ssh", "-At", "build", "/bin/sh -c \(shellQuote(script))"])
    }

    @MainActor
    func testRemoteAgentCommandInstallsEnvironmentBeforeSelectedRemoteShellParsesCommand() {
        let command = "printf '%s' \"$REPO:$THREAD_ID\"; untouched=$(remote-only)"
        let arguments = WorkspaceModel.remoteShellCommandArguments(
            server: "devbox",
            remoteWorkingDirectory: "/worktrees/feature's copy",
            shellCommand: command,
            environment: [
                "REPO": "/repos/project",
                "AGENT_NAME": "reviewer's-agent",
                "THREAD_ID": "thread-$REMOTE"
            ]
        )

        let invocation = [
            "/usr/bin/env",
            "AGENT_NAME=reviewer's-agent",
            "REPO=/repos/project",
            "THREAD_ID=thread-$REMOTE"
        ].map { shellQuote($0) }.joined(separator: " ")
            + " \"${SHELL:-/bin/sh}\" -l -c \(shellQuote(command))"
        let script = "cd \(shellQuote("/worktrees/feature's copy")) && exec \(invocation)"
        XCTAssertEqual(
            arguments,
            ["ssh", "-At", "devbox", "/bin/sh -c \(shellQuote(script))"]
        )
    }

    @MainActor
    func testRemoteBuiltInCodexDispatcherSelectsTheShellOnTheRemoteHost() {
        let arguments = WorkspaceModel.remoteShellCommandArguments(
            server: "devbox",
            remoteWorkingDirectory: "/srv/project",
            shellCommand: "ignored session wrapper",
            environment: [
                "REPO": "/srv/project",
                "REPO_ID": "project",
                "AGENT_PROFILE": "codex",
                "AGENT_NAME": "reviewer"
            ],
            builtInCodexBody: #"exec codex --add-dir "$REPO""#
        )

        XCTAssertEqual(Array(arguments.prefix(3)), ["ssh", "-At", "devbox"])
        XCTAssertTrue(arguments[3].contains("command -v shpool"))
        XCTAssertTrue(arguments[3].contains("command -v atch"))
        XCTAssertTrue(arguments[3].contains("${SHELL:-/bin/sh}"))
        XCTAssertTrue(arguments[3].contains("exec codex --add-dir"))
        XCTAssertFalse(arguments[3].contains("ignored session wrapper"))
    }

    @MainActor
    func testShellCommandLaunchUsesSelectedLoginShellAndStableEnvironmentArguments() {
        XCTAssertEqual(
            WorkspaceModel.shellCommandArguments(
                shellCommand: "printf ok",
                environment: ["ZED": "last", "ALPHA": "first"],
                processEnvironment: ["SHELL": "/tmp/a shell/fish"]
            ),
            [
                "/usr/bin/env",
                "ALPHA=first",
                "ZED=last",
                "/tmp/a shell/fish",
                "-l",
                "-c",
                "printf ok"
            ]
        )
    }

    @MainActor
    func testShellCommandLaunchFallsBackToBinShForMissingOrEmptyShell() {
        for processEnvironment in [[:], ["SHELL": ""], ["SHELL": "  \n"]] {
            XCTAssertEqual(
                WorkspaceModel.shellCommandArguments(
                    shellCommand: "printf ok",
                    environment: [:],
                    processEnvironment: processEnvironment
                ),
                ["/usr/bin/env", "/bin/sh", "-l", "-c", "printf ok"]
            )
        }
    }

    @MainActor
    func testCustomProfileCommandReachesSelectedShellVerbatimAfterEnvironmentIsSet() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("fake fish")
        let capture = directory.appendingPathComponent("capture")
        try """
        #!/bin/sh
        [ "$1" = "-l" ] || exit 61
        [ "$2" = "-c" ] || exit 62
        printf '%s\n%s\n' "$AGENT_NAME" "$3" > "$CAPTURE"
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let command = "printf '$REPO' && echo custom; value=\"$(not-expanded-yet)\""
        let arguments = WorkspaceModel.shellCommandArguments(
            shellCommand: command,
            environment: ["AGENT_NAME": "builder", "CAPTURE": capture.path],
            processEnvironment: ["SHELL": shell.path]
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            try String(contentsOf: capture, encoding: .utf8),
            "builder\n\(command)\n"
        )
    }

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

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
