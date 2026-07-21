import Foundation
import DevHQLua
import Lua
import SwiftUI

enum WindowTheme: String {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension WindowTheme: LuaPluginValue {
    func push(onto state: LuaPluginState) {
        state.push(rawValue)
    }

    static func read(from state: LuaPluginState, at index: CInt) throws -> WindowTheme {
        let value = try String.read(from: state, at: index)
        guard let theme = WindowTheme(rawValue: value) else {
            throw PluginAPIError.invalidValue("theme", value)
        }
        return theme
    }
}

enum SplitDirection: String {
    case horizontal
    case vertical
}

extension SplitDirection: LuaPluginValue {
    func push(onto state: LuaPluginState) {
        state.push(rawValue)
    }

    static func read(from state: LuaPluginState, at index: CInt) throws -> SplitDirection {
        let value = try String.read(from: state, at: index)
        guard let direction = SplitDirection(rawValue: value) else {
            throw PluginAPIError.invalidValue("split direction", value)
        }
        return direction
    }
}

@MainActor
final class EditorSettings: ObservableObject {
    @Published var windowTheme = WindowTheme.system
    @Published var splitDirection = SplitDirection.horizontal
    @Published var treeViewVisible = true
    @Published var treeViewSize = 250.0
    @Published var showGutter = true
    @Published var showMinimap = true
    @Published var showFoldingRibbon = true
    @Published var pluginError: String?
}

private enum PluginAPIError: LocalizedError {
    case invalidValue(String, String)

    var errorDescription: String? {
        switch self {
        case let .invalidValue(kind, value):
            "Invalid \(kind) value: \(value)"
        }
    }
}

@MainActor
@LuaModule("core")
private final class LuaCoreAPI {
    @LuaField("api_version")
    let apiVersion: String

    @LuaField("config_dir")
    let configDirectory: String

    init(apiVersion: String, configDirectory: String) {
        self.apiVersion = apiVersion
        self.configDirectory = configDirectory
    }

    @LuaFunction("log")
    func log(_ message: String) {
        print("[devhq.lua] \(message)")
    }
}

@MainActor
@LuaModule("window")
private final class LuaWindowAPI {
    let settings: EditorSettings

    init(settings: EditorSettings) {
        self.settings = settings
    }

    @LuaField("theme")
    var theme: WindowTheme {
        get { settings.windowTheme }
        set { settings.windowTheme = newValue }
    }

    @LuaFunction("set_theme")
    func setTheme(_ value: String) throws {
        guard let theme = WindowTheme(rawValue: value) else {
            throw PluginAPIError.invalidValue("theme", value)
        }
        self.theme = theme
    }

    @LuaFunction("get_theme")
    func getTheme() -> String {
        theme.rawValue
    }
}

@MainActor
@LuaModule("split")
private final class LuaSplitAPI {
    let settings: EditorSettings

    init(settings: EditorSettings) {
        self.settings = settings
    }

    @LuaField("direction")
    var direction: SplitDirection {
        get { settings.splitDirection }
        set { settings.splitDirection = newValue }
    }

    @LuaFunction("set_direction")
    func setDirection(_ value: String) throws {
        guard let direction = SplitDirection(rawValue: value) else {
            throw PluginAPIError.invalidValue("split direction", value)
        }
        self.direction = direction
    }

    @LuaFunction("get_direction")
    func getDirection() -> String {
        direction.rawValue
    }
}

@MainActor
@LuaModule("treeview")
private final class LuaTreeViewAPI {
    let settings: EditorSettings

    init(settings: EditorSettings) {
        self.settings = settings
    }

    @LuaField("visible")
    var visible: Bool {
        get { settings.treeViewVisible }
        set { settings.treeViewVisible = newValue }
    }

    @LuaField("size")
    var size: Double {
        get { settings.treeViewSize }
        set { settings.treeViewSize = min(max(newValue, 120), 600) }
    }

    @LuaFunction("set_visible")
    func setVisible(_ visible: Bool) {
        self.visible = visible
    }

    @LuaFunction("is_visible")
    func isVisible() -> Bool {
        visible
    }

    @LuaFunction("set_size")
    func setSize(_ size: Double) {
        self.size = size
    }

    @LuaFunction("get_size")
    func getSize() -> Double {
        size
    }
}

@MainActor
@LuaModule("docview")
private final class LuaDocViewAPI {
    let settings: EditorSettings

    init(settings: EditorSettings) {
        self.settings = settings
    }

    @LuaField("gutter")
    var gutter: Bool {
        get { settings.showGutter }
        set { settings.showGutter = newValue }
    }

    @LuaField("minimap")
    var minimap: Bool {
        get { settings.showMinimap }
        set { settings.showMinimap = newValue }
    }

    @LuaField("folding")
    var folding: Bool {
        get { settings.showFoldingRibbon }
        set { settings.showFoldingRibbon = newValue }
    }

    @LuaFunction("set_gutter")
    func setGutter(_ visible: Bool) {
        gutter = visible
    }

    @LuaFunction("set_minimap")
    func setMinimap(_ visible: Bool) {
        minimap = visible
    }

    @LuaFunction("set_folding")
    func setFolding(_ visible: Bool) {
        folding = visible
    }
}

@MainActor
final class LuaPluginHost: ObservableObject {
    static let apiVersion = "0.2"

    let settings: EditorSettings
    let configDirectory: URL
    let commandManager: CommandManager
    private weak var workspace: WorkspaceModel?
    private let state = LuaState(libraries: .all)

    convenience init() {
        self.init(
            settings: EditorSettings(),
            configDirectory: Self.defaultConfigDirectory(),
            commandManager: CommandManager()
        )
    }

    convenience init(commandManager: CommandManager, workspace: WorkspaceModel? = nil) {
        self.init(
            settings: EditorSettings(),
            configDirectory: Self.defaultConfigDirectory(),
            commandManager: commandManager,
            workspace: workspace
        )
    }

    convenience init(settings: EditorSettings, configDirectory: URL) {
        self.init(
            settings: settings,
            configDirectory: configDirectory,
            commandManager: CommandManager()
        )
    }

    init(
        settings: EditorSettings,
        configDirectory: URL,
        commandManager: CommandManager,
        workspace: WorkspaceModel? = nil
    ) {
        self.settings = settings
        self.configDirectory = configDirectory
        self.commandManager = commandManager
        self.workspace = workspace
        state.setRequireRoot(configDirectory.path)
        do {
            try registerModule()
        } catch {
            settings.pluginError = "Could not initialize Lua: \(error.localizedDescription)"
        }
    }

    deinit {
        state.close()
    }

    func loadUserConfiguration() {
        let scriptURL = configDirectory.appendingPathComponent("init.lua")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return }
        do {
            try loadScript(at: scriptURL)
        } catch {
            settings.pluginError = "\(scriptURL.path): \(error.localizedDescription)"
        }
    }

    func loadScript(at url: URL) throws {
        defer { state.settop(0) }
        try state.dofile(url.path)
    }

    nonisolated static func defaultConfigDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["DEVHQ_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/devhq", isDirectory: true)
    }

    private func registerModule() throws {
        let commandAPI = LuaCommandAPI(commandManager: commandManager)
        commandAPI.pushLuaTable(onto: state)
        let commandTable = state.popref()
        let openCommandModule: LuaClosure = { state in
            state.push(commandTable)
            return 1
        }
        try state.requiref(name: commandAPI.luaName, global: false) {
            state.push(openCommandModule)
        }

        let terminalAPI = LuaTerminalAPI(workspace: workspace)
        terminalAPI.pushLuaTable(onto: state)
        let terminalTable = state.popref()
        let openTerminalModule: LuaClosure = { state in
            state.push(terminalTable)
            return 1
        }
        try state.requiref(name: terminalAPI.luaName, global: false) {
            state.push(openTerminalModule)
        }

        let modules: [any LuaModuleRegistrable] = [
            LuaCoreAPI(apiVersion: Self.apiVersion, configDirectory: configDirectory.path),
            LuaWindowAPI(settings: settings),
            LuaSplitAPI(settings: settings),
            LuaTreeViewAPI(settings: settings),
            LuaDocViewAPI(settings: settings)
        ]
        let openModule: LuaClosure = { state in
            state.newtable(nrec: CInt(modules.count + 2))
            for module in modules {
                module.pushLuaTable(onto: state)
                state.rawset(-2, utf8Key: module.luaName)
            }
            state.push(commandTable)
            state.rawset(-2, utf8Key: commandAPI.luaName)
            state.push(terminalTable)
            state.rawset(-2, utf8Key: terminalAPI.luaName)
            return 1
        }
        try state.requiref(name: "devhq", global: false) {
            state.push(openModule)
        }
    }

}
