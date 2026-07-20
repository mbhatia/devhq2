import Foundation
import XCTest
@testable import DevHQ

final class LuaCommandTests: XCTestCase {
    @MainActor
    func testLuaCommandsSurviveConfigurationLoadAndRespectScopes() throws {
        let directory = try makeConfigurationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeInit(
            """
            local command = require "command"
            local devhq = require "devhq"
            assert(command == devhq.command)

            command.add("lua:global", nil, function()
              devhq.window.theme = "dark"
            end)
            command.add("lua:document", "document", function()
              devhq.window.theme = "light"
            end)
            command.add("lua:file-only", function(view)
              return view == "file"
            end, function()
              devhq.treeview.visible = false
            end)

            collectgarbage("collect")
            """,
            in: directory
        )

        let settings = EditorSettings()
        let manager = CommandManager()
        let host = LuaPluginHost(
            settings: settings,
            configDirectory: directory,
            commandManager: manager
        )
        host.loadUserConfiguration()

        XCTAssertNil(settings.pluginError)
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .worktree)).map(\.id),
            ["lua:global"]
        )
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .file)).map(\.id),
            ["lua:file-only", "lua:global"]
        )
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .document)).map(\.id),
            ["lua:document", "lua:global"]
        )

        try manager.execute(id: "lua:global", in: CommandContext(view: .worktree))
        XCTAssertEqual(settings.windowTheme, .dark)
        try manager.execute(id: "lua:document", in: CommandContext(view: .document))
        XCTAssertEqual(settings.windowTheme, .light)
        try manager.execute(id: "lua:file-only", in: CommandContext(view: .file))
        XCTAssertFalse(settings.treeViewVisible)
    }

    @MainActor
    func testLuaCommandReplacementAndRemovalReleaseRegistrations() throws {
        let directory = try makeConfigurationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeInit(
            """
            local command = require "command"
            local devhq = require "devhq"

            command.add("lua:replace", nil, function()
              devhq.window.theme = "dark"
            end)
            command.add("lua:replace", nil, function()
              devhq.window.theme = "light"
            end)

            command.add("lua:remove-self", nil, function()
              assert(command.remove("lua:remove-self"))
              collectgarbage("collect")
              devhq.treeview.visible = false
            end)

            command.add("lua:removed", nil, function() end)
            assert(command.remove("lua:removed"))
            assert(not command.remove("lua:removed"))
            """,
            in: directory
        )

        let settings = EditorSettings()
        let manager = CommandManager()
        let host = LuaPluginHost(
            settings: settings,
            configDirectory: directory,
            commandManager: manager
        )
        host.loadUserConfiguration()

        XCTAssertNil(settings.pluginError)
        XCTAssertNil(manager.commandsByID["lua:removed"])
        try manager.execute(id: "lua:replace", in: CommandContext(view: .document))
        XCTAssertEqual(settings.windowTheme, .light)

        try manager.execute(id: "lua:remove-self", in: CommandContext(view: .file))
        XCTAssertFalse(settings.treeViewVisible)
        XCTAssertNil(manager.commandsByID["lua:remove-self"])
    }

    @MainActor
    func testExternalLuaPluginCanRegisterAndRemoveCommands() throws {
        let directory = try makeConfigurationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pluginsDirectory = directory.appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pluginsDirectory,
            withIntermediateDirectories: true
        )
        try """
        local command = require "command"
        local devhq = require "devhq"

        command.add("external:run", "document", function()
          devhq.window.theme = "dark"
        end)
        command.add("external:removed", nil, function() end)
        assert(command.remove("external:removed"))

        return {}
        """.write(
            to: pluginsDirectory.appendingPathComponent("commands.lua"),
            atomically: true,
            encoding: .utf8
        )
        try writeInit(
            """
            require "plugins.commands"
            """,
            in: directory
        )

        let settings = EditorSettings()
        let manager = CommandManager()
        let host = LuaPluginHost(
            settings: settings,
            configDirectory: directory,
            commandManager: manager
        )
        host.loadUserConfiguration()

        XCTAssertNil(settings.pluginError)
        XCTAssertNil(manager.commandsByID["external:removed"])
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .document)).map(\.id),
            ["external:run"]
        )
        XCTAssertTrue(try manager.commands(in: CommandContext(view: .file)).isEmpty)

        try manager.execute(id: "external:run", in: CommandContext(view: .document))
        XCTAssertEqual(settings.windowTheme, .dark)
    }

    @MainActor
    func testLuaCommandArgumentAndCallbackErrorsAreProtected() throws {
        let directory = try makeConfigurationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeInit(
            """
            local command = require "command"

            local ok, error_message = pcall(command.add, "lua:bad-action", nil, 42)
            assert(not ok and string.find(error_message, "argument 3"))

            ok, error_message = pcall(command.add, "lua:bad-view", "editor", function() end)
            assert(not ok and string.find(error_message, "Invalid command view kind"))

            ok, error_message = pcall(command.add, "lua:bad-predicate", 42, function() end)
            assert(not ok and string.find(error_message, "argument 2"))

            command.add("lua:wrong-result", function()
              return "yes"
            end, function() end)

            command.add("lua:predicate-error", function()
              error("predicate failed")
            end, function() end)

            command.add("lua:action-error", nil, function()
              error("action failed")
            end)
            """,
            in: directory
        )

        let manager = CommandManager()
        let host = LuaPluginHost(
            settings: EditorSettings(),
            configDirectory: directory,
            commandManager: manager
        )
        host.loadUserConfiguration()

        XCTAssertNil(host.settings.pluginError)
        XCTAssertThrowsError(
            try manager.commands(in: CommandContext(view: .document))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("predicate"))
        }
        XCTAssertThrowsError(
            try manager.execute(id: "lua:wrong-result", in: CommandContext(view: .document))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("must return a boolean"))
        }
        XCTAssertThrowsError(
            try manager.execute(id: "lua:action-error", in: CommandContext(view: .document))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("action failed"))
        }
    }

    private func makeConfigurationDirectory() throws -> URL {
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
