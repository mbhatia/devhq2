import Foundation
import XCTest
@testable import DevHQ

final class LuaContextMenuAPITests: XCTestCase {
    @MainActor
    func testLuaRegistrationReplacementRemovalAndReadOnlySnapshot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeInit(
            """
            local context_menu = require "context_menu"
            local devhq = require "devhq"
            assert(context_menu == devhq.context_menu)

            context_menu.add({
              id = "plugin:first",
              title = "First",
              targets = { "file.file" },
              action = function() error("replaced action ran") end,
            })
            context_menu.add({
              id = "plugin:second",
              title = "Second",
              targets = { "worktree.repository" },
              action = function() end,
            })
            context_menu.add({
              id = "plugin:first",
              title = "Replacement",
              targets = { "file.file", "file.directory" },
              action = function(node)
                assert(node.explorer == "file")
                assert(node.kind == "file")
                assert(node.name == "main.swift")
                assert(node.path == "/repo/main.swift")
                assert(node.repository_name == nil)
                assert(getmetatable(node) == false)
                local changed, message = pcall(function() node.name = "changed" end)
                assert(not changed and string.find(message, "read%-only"))
              end,
            })
            assert(context_menu.remove("plugin:second"))
            assert(not context_menu.remove("plugin:second"))
            """,
            in: directory
        )

        let registry = ContextMenuRegistry()
        let host = LuaPluginHost(
            settings: EditorSettings(),
            configDirectory: directory,
            commandManager: CommandManager(),
            contextMenuRegistry: registry
        )
        host.loadUserConfiguration()

        XCTAssertNil(host.settings.pluginError)
        XCTAssertEqual(registry.registeredItems.map(\.id), ["plugin:first"])
        XCTAssertEqual(registry.registeredItems.map(\.title), ["Replacement"])
        XCTAssertEqual(registry.items(for: .fileFile).map(\.id), ["plugin:first"])
        XCTAssertEqual(registry.items(for: .fileDirectory).map(\.id), ["plugin:first"])
        XCTAssertTrue(registry.items(for: .worktreeRepository).isEmpty)

        try XCTUnwrap(registry.registeredItems.first).perform(with: ContextMenuSnapshot(
            target: .fileFile,
            name: "main.swift",
            path: "/repo/main.swift"
        ))
    }

    @MainActor
    func testLuaRegistrationAndCallbackErrorsAreProtected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeInit(
            """
            local context_menu = require "context_menu"
            local function expect_error(action, fragment)
              local ok, message = pcall(action)
              assert(not ok and string.find(message, fragment, 1, true), message)
            end

            expect_error(function() context_menu.add(false) end, "options table")
            expect_error(function() context_menu.add({}) end, "'id'")
            expect_error(function()
              context_menu.add({ id = "bad", title = "Bad", targets = {}, action = function() end })
            end, "dense array")
            expect_error(function()
              context_menu.add({
                id = "bad", title = "Bad", targets = { "file.unknown" }, action = function() end,
              })
            end, "Invalid context menu target")
            expect_error(function()
              context_menu.add({ id = "bad", title = "Bad", targets = { "file.file" }, action = 42 })
            end, "must be a function")

            context_menu.add({
              id = "plugin:error",
              title = "Error",
              targets = { "worktree.worktree" },
              action = function() error("action failed") end,
            })
            """,
            in: directory
        )

        let registry = ContextMenuRegistry()
        let host = LuaPluginHost(
            settings: EditorSettings(),
            configDirectory: directory,
            commandManager: CommandManager(),
            contextMenuRegistry: registry
        )
        host.loadUserConfiguration()

        XCTAssertNil(host.settings.pluginError)
        XCTAssertThrowsError(try XCTUnwrap(registry.registeredItems.first).perform(
            with: ContextMenuSnapshot(
                target: .worktreeWorktree,
                name: "feature",
                path: "/repo/.worktrees/feature"
            )
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("action failed"))
        }
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
