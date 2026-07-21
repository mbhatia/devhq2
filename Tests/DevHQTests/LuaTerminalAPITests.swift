import Foundation
import XCTest
@testable import DevHQ

final class LuaTerminalAPITests: XCTestCase {
    @MainActor
    func testLuaCreatesTerminalWithWorkingDirectoryAndCommand() throws {
        let configuration = try temporaryDirectory()
        let workspaceRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: configuration)
            try? FileManager.default.removeItem(at: workspaceRoot)
        }
        let child = workspaceRoot.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writeInit(
            """
            local terminal = require "terminal"
            local devhq = require "devhq"
            assert(terminal == devhq.terminal)

            local id = terminal.new({
              cwd = "child",
              command = { "/bin/sh", "-c", "printf lua-terminal; pwd" },
            })
            assert(type(id) == "string" and #id > 0)
            """,
            in: configuration
        )

        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(workspaceRoot)
        let host = LuaPluginHost(
            settings: EditorSettings(),
            configDirectory: configuration,
            commandManager: CommandManager(),
            workspace: workspace
        )
        host.loadUserConfiguration()

        XCTAssertNil(host.settings.pluginError)
        let session = try XCTUnwrap(workspace.selectedTerminal)
        defer { workspace.closeAllTerminals() }
        XCTAssertEqual(session.currentDirectory, child.standardizedFileURL.resolvingSymlinksInPath())

        let deadline = Date().addingTimeInterval(3)
        while session.exitStatus == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let output = session.snapshot.cells.flatMap { $0 }.map(\.text).joined()
        XCTAssertEqual(session.exitStatus, 0)
        XCTAssertTrue(output.contains("lua-terminal"))
        XCTAssertTrue(output.contains(child.path))
    }

    @MainActor
    func testLuaTerminalOptionsReportClearValidationErrors() throws {
        let configuration = try temporaryDirectory()
        let workspaceRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: configuration)
            try? FileManager.default.removeItem(at: workspaceRoot)
        }
        try writeInit(
            """
            local terminal = require "terminal"

            local function expect_error(action, fragment)
              local ok, message = pcall(action)
              assert(not ok and string.find(message, fragment, 1, true), message)
            end

            expect_error(function() terminal.new(false) end, "nil or a table")
            expect_error(function() terminal.new({ cwd = false }) end, "cwd")
            expect_error(function() terminal.new({ cwd = "missing" }) end, "does not exist")
            expect_error(function() terminal.new({ command = {} }) end, "dense array")
            expect_error(function()
              terminal.new({ command = { "/bin/echo", false } })
            end, "dense array")
            expect_error(function()
              terminal.new({ command = { [1] = "/bin/echo", [3] = "gap" } })
            end, "dense array")
            expect_error(function()
              terminal.new({ command = { "/bin/echo", string.char(0) } })
            end, "null byte")
            local too_many_arguments = {}
            for index = 1, 1025 do
              too_many_arguments[index] = "argument"
            end
            expect_error(function()
              terminal.new({ command = too_many_arguments })
            end, "at most 1024")
            """,
            in: configuration
        )

        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        workspace.openWorkspace(workspaceRoot)
        let host = LuaPluginHost(
            settings: EditorSettings(),
            configDirectory: configuration,
            commandManager: CommandManager(),
            workspace: workspace
        )
        host.loadUserConfiguration()

        XCTAssertNil(host.settings.pluginError)
        XCTAssertTrue(workspace.terminalSessions.isEmpty)
    }

    @MainActor
    func testLuaTerminalRequiresAnInjectedOpenWorkspace() throws {
        let configuration = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: configuration) }
        try writeInit(
            """
            local terminal = require "terminal"
            local ok, message = pcall(terminal.new)
            assert(not ok and string.find(message, "unavailable", 1, true), message)
            """,
            in: configuration
        )

        let host = LuaPluginHost(
            settings: EditorSettings(),
            configDirectory: configuration,
            commandManager: CommandManager()
        )
        host.loadUserConfiguration()
        XCTAssertNil(host.settings.pluginError)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeInit(_ source: String, in directory: URL) throws {
        try source.write(
            to: directory.appendingPathComponent("init.lua"),
            atomically: true,
            encoding: .utf8
        )
    }
}
