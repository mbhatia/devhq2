import Foundation
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

enum SplitDirection: String {
    case horizontal
    case vertical
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
final class LuaPluginHost: ObservableObject {
    static let apiVersion = "0.1"

    let settings: EditorSettings
    let configDirectory: URL
    private let state = LuaState(libraries: .all)

    convenience init() {
        self.init(
            settings: EditorSettings(),
            configDirectory: Self.defaultConfigDirectory()
        )
    }

    init(settings: EditorSettings, configDirectory: URL) {
        self.settings = settings
        self.configDirectory = configDirectory
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
        let openModule: LuaClosure = { [settings, configDirectory] state in
            state.newtable(nrec: 5)
            Self.addCore(to: state, configDirectory: configDirectory)
            Self.addWindow(to: state, settings: settings)
            Self.addSplit(to: state, settings: settings)
            Self.addTreeView(to: state, settings: settings)
            Self.addDocView(to: state, settings: settings)
            return 1
        }
        try state.requiref(name: "devhq", global: false) {
            state.push(openModule)
        }
    }

    private static func addCore(to state: LuaState, configDirectory: URL) {
        state.newtable(nrec: 3)
        state.push(apiVersion)
        state.rawset(-2, utf8Key: "api_version")
        state.push(configDirectory.path)
        state.rawset(-2, utf8Key: "config_dir")
        function("log", in: state) { state in
            print("[devhq.lua] \(state.tostring(1, convert: true) ?? "")")
            return 0
        }
        state.rawset(-2, utf8Key: "core")
    }

    private static func addWindow(to state: LuaState, settings: EditorSettings) {
        state.newtable(nrec: 2)
        function("set_theme", in: state) { state in
            let value = state.tostring(1) ?? ""
            guard let theme = WindowTheme(rawValue: value) else {
                throw PluginAPIError.invalidValue("theme", value)
            }
            settings.windowTheme = theme
            return 0
        }
        function("get_theme", in: state) { state in
            state.push(settings.windowTheme.rawValue)
            return 1
        }
        state.rawset(-2, utf8Key: "window")
    }

    private static func addSplit(to state: LuaState, settings: EditorSettings) {
        state.newtable(nrec: 2)
        function("set_direction", in: state) { state in
            let value = state.tostring(1) ?? ""
            guard let direction = SplitDirection(rawValue: value) else {
                throw PluginAPIError.invalidValue("split direction", value)
            }
            settings.splitDirection = direction
            return 0
        }
        function("get_direction", in: state) { state in
            state.push(settings.splitDirection.rawValue)
            return 1
        }
        state.rawset(-2, utf8Key: "split")
    }

    private static func addTreeView(to state: LuaState, settings: EditorSettings) {
        state.newtable(nrec: 4)
        function("set_visible", in: state) { state in
            settings.treeViewVisible = state.toboolean(1)
            return 0
        }
        function("is_visible", in: state) { state in
            state.push(settings.treeViewVisible)
            return 1
        }
        function("set_size", in: state) { state in
            guard let value = state.tonumber(1) else {
                throw PluginAPIError.invalidValue("tree view size", "non-number")
            }
            settings.treeViewSize = min(max(value, 120), 600)
            return 0
        }
        function("get_size", in: state) { state in
            state.push(settings.treeViewSize)
            return 1
        }
        state.rawset(-2, utf8Key: "treeview")
    }

    private static func addDocView(to state: LuaState, settings: EditorSettings) {
        state.newtable(nrec: 3)
        function("set_gutter", in: state) { state in
            settings.showGutter = state.toboolean(1)
            return 0
        }
        function("set_minimap", in: state) { state in
            settings.showMinimap = state.toboolean(1)
            return 0
        }
        function("set_folding", in: state) { state in
            settings.showFoldingRibbon = state.toboolean(1)
            return 0
        }
        state.rawset(-2, utf8Key: "docview")
    }

    private static func function(
        _ name: String,
        in state: LuaState,
        body: @escaping LuaClosure
    ) {
        state.push(body)
        state.rawset(-2, utf8Key: name)
    }
}
