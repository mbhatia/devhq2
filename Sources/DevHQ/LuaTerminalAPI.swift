import DevHQLua
import Foundation
import Lua

private enum LuaTerminalAPIError: LocalizedError {
    case unavailable
    case noWorkspace
    case invalidOptions
    case invalidWorkingDirectory
    case workingDirectoryNotFound(String)
    case invalidCommand
    case tooManyCommandArguments
    case stringContainsNull(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The terminal API is unavailable in this Lua host."
        case .noWorkspace:
            "Open a workspace before launching a terminal."
        case .invalidOptions:
            "terminal.new options must be nil or a table."
        case .invalidWorkingDirectory:
            "terminal.new option 'cwd' must be a string."
        case .workingDirectoryNotFound(let path):
            "Terminal working directory does not exist or is not a directory: \(path)"
        case .invalidCommand:
            "terminal.new option 'command' must be a non-empty dense array of strings."
        case .tooManyCommandArguments:
            "terminal.new option 'command' accepts at most 1024 arguments."
        case .stringContainsNull(let option):
            "terminal.new option '\(option)' cannot contain a null byte."
        }
    }
}

@MainActor
final class LuaTerminalAPI: LuaModuleRegistrable {
    private static let maximumCommandArgumentCount: lua_Integer = 1024

    let luaName = "terminal"

    private weak var workspace: WorkspaceModel?

    init(workspace: WorkspaceModel?) {
        self.workspace = workspace
    }

    func pushLuaTable(onto state: LuaPluginState) {
        state.newtable(nrec: 1)
        LuaBridge.addFunction(named: "new", to: state) { [weak workspace] state in
            guard let workspace else { throw LuaTerminalAPIError.unavailable }
            guard let rootURL = workspace.rootURL else { throw LuaTerminalAPIError.noWorkspace }

            let optionsIndex: CInt?
            switch state.type(1) {
            case nil, .nil:
                optionsIndex = nil
            case .table:
                optionsIndex = 1
            default:
                throw LuaTerminalAPIError.invalidOptions
            }

            let workingDirectory = try Self.workingDirectory(
                from: state,
                optionsIndex: optionsIndex,
                rootURL: rootURL
            )
            let command = try Self.command(from: state, optionsIndex: optionsIndex)
            let terminal = try workspace.newTerminal(
                workingDirectory: workingDirectory,
                command: command,
                shell: nil
            )
            state.push(terminal.id.uuidString)
            return 1
        }
    }

    private static func workingDirectory(
        from state: LuaPluginState,
        optionsIndex: CInt?,
        rootURL: URL
    ) throws -> URL? {
        guard let optionsIndex else { return nil }
        state.rawget(optionsIndex, utf8Key: "cwd")
        defer { state.pop() }

        let path: String
        switch state.type(-1) {
        case .nil:
            return nil
        case .string:
            guard let value = state.tostring(-1) else {
                throw LuaTerminalAPIError.invalidWorkingDirectory
            }
            path = value
        default:
            throw LuaTerminalAPIError.invalidWorkingDirectory
        }
        guard !path.utf8.contains(0) else {
            throw LuaTerminalAPIError.stringContainsNull("cwd")
        }

        let url = (path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : rootURL.appendingPathComponent(path, isDirectory: true))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LuaTerminalAPIError.workingDirectoryNotFound(url.path)
        }
        return url
    }

    private static func command(
        from state: LuaPluginState,
        optionsIndex: CInt?
    ) throws -> [String]? {
        guard let optionsIndex else { return nil }
        state.rawget(optionsIndex, utf8Key: "command")
        defer { state.pop() }

        guard state.type(-1) != .nil else { return nil }
        guard state.type(-1) == .table,
              let rawLength = state.rawlen(-1),
              rawLength > 0,
              rawLength <= lua_Integer(Int.max) else {
            throw LuaTerminalAPIError.invalidCommand
        }
        guard rawLength <= maximumCommandArgumentCount else {
            throw LuaTerminalAPIError.tooManyCommandArguments
        }

        let commandIndex = state.absindex(-1)
        let length = Int(rawLength)
        var values = Array<String?>(repeating: nil, count: length)
        var entryCount = 0
        for (keyIndex, valueIndex) in state.pairs(commandIndex) {
            guard state.type(keyIndex) == .number,
                  let rawKey = state.tointeger(keyIndex),
                  rawKey >= 1,
                  rawKey <= rawLength,
                  state.type(valueIndex) == .string,
                  let value = state.tostring(valueIndex) else {
                throw LuaTerminalAPIError.invalidCommand
            }
            guard !value.utf8.contains(0) else {
                throw LuaTerminalAPIError.stringContainsNull("command")
            }
            let index = Int(rawKey) - 1
            guard values[index] == nil else { throw LuaTerminalAPIError.invalidCommand }
            values[index] = value
            entryCount += 1
        }
        guard entryCount == length, values.allSatisfy({ $0 != nil }) else {
            throw LuaTerminalAPIError.invalidCommand
        }
        return values.compactMap { $0 }
    }
}
