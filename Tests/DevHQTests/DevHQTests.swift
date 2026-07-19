import Foundation
import XCTest
@testable import DevHQ
import CodeEditLanguages
import DevHQLua

private enum LuaMacroFixtureError: Error {
    case rejected
}

@MainActor
@LuaModule("fixture")
public final class LuaMacroFixture {
    @LuaField("label")
    var label: String

    @LuaField("identifier")
    let identifier: String

    init(label: String, identifier: String) {
        self.label = label
        self.identifier = identifier
    }

    @LuaFunction("describe")
    func describe(_ state: String, count: Int, enabled: Bool) -> String {
        "\(state):\(count):\(enabled)"
    }

    @LuaFunction("reject")
    func reject() throws {
        throw LuaMacroFixtureError.rejected
    }
}

final class DevHQTests: XCTestCase {
    @MainActor
    func testLuaMacrosExposeFieldsTypedMethodsAndErrors() throws {
        let state = LuaPluginState(libraries: .all)
        defer { state.close() }

        let fixture = LuaMacroFixture(label: "generated", identifier: "fixed")
        fixture.pushLuaTable(onto: state)
        state.setglobal(name: fixture.luaName)
        fixture.label = "changed-in-swift"

        try state.dostring("""
        assert(fixture.label == "changed-in-swift")
        fixture.label = "changed-in-lua"
        assert(fixture.label == "changed-in-lua")
        assert(fixture.identifier == "fixed")
        assert(fixture.describe("item", 3, true) == "item:3:true")

        local changed_identifier, field_error = pcall(function()
          fixture.identifier = "replacement"
        end)
        assert(not changed_identifier)
        assert(string.find(field_error, "read%-only"))

        fixture.plugin_value = "allowed"
        assert(fixture.plugin_value == "allowed")

        local valid_argument, argument_error = pcall(fixture.describe, "item", "three", true)
        assert(not valid_argument)
        assert(string.find(argument_error, "argument 2"))

        local accepted = pcall(fixture.reject)
        assert(not accepted)
        """)

        XCTAssertEqual(fixture.label, "changed-in-lua")
        XCTAssertEqual(fixture.identifier, "fixed")
    }

    @MainActor
    func testLuaUserConfigurationCustomizesCoreEditorObjects() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pluginsDirectory = directory.appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let plugin = """
        local plugin = {}
        function plugin.apply(devhq)
          devhq.split.set_direction("vertical")
          devhq.treeview.set_visible(false)
          devhq.treeview.set_size(333)
          devhq.docview.set_gutter(false)
          devhq.docview.set_minimap(false)
          devhq.docview.set_folding(false)
        end
        return plugin
        """
        try plugin.write(
            to: pluginsDirectory.appendingPathComponent("layout.lua"),
            atomically: true,
            encoding: .utf8
        )

        let script = """
        local devhq = require "devhq"
        local layout = require "plugins.layout"
        assert(devhq.core.api_version == "0.1")
        devhq.window.theme = "dark"
        layout.apply(devhq)
        devhq.split.direction = "vertical"
        devhq.treeview.visible = false
        devhq.treeview.size = 999
        assert(devhq.treeview.size == 600)
        devhq.treeview.size = 333
        devhq.docview.gutter = false
        devhq.docview.minimap = false
        devhq.docview.folding = false

        local changed_theme, theme_error = pcall(function()
          devhq.window.theme = "invalid"
        end)
        assert(not changed_theme)
        assert(string.find(theme_error, "Invalid theme"))
        assert(devhq.window.theme == "dark")

        local changed_version, version_error = pcall(function()
          devhq.core.api_version = "invalid"
        end)
        assert(not changed_version)
        assert(string.find(version_error, "read%-only"))
        """
        try script.write(
            to: directory.appendingPathComponent("init.lua"),
            atomically: true,
            encoding: .utf8
        )

        let settings = EditorSettings()
        let host = LuaPluginHost(settings: settings, configDirectory: directory)
        host.loadUserConfiguration()

        XCTAssertNil(settings.pluginError)
        XCTAssertEqual(settings.windowTheme, .dark)
        XCTAssertEqual(settings.splitDirection, .vertical)
        XCTAssertFalse(settings.treeViewVisible)
        XCTAssertEqual(settings.treeViewSize, 333)
        XCTAssertFalse(settings.showGutter)
        XCTAssertFalse(settings.showMinimap)
        XCTAssertFalse(settings.showFoldingRibbon)
    }

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
