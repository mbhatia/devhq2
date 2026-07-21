import DevHQLua
import Foundation
import Lua

private enum LuaContextMenuAPIError: LocalizedError {
    case optionsMustBeTable
    case missingString(String)
    case targetsMustBeArray
    case invalidTarget(String)
    case actionMustBeFunction
    case readOnlySnapshot

    var errorDescription: String? {
        switch self {
        case .optionsMustBeTable:
            "context_menu.add expects one options table."
        case .missingString(let name):
            "context_menu.add option '\(name)' must be a non-empty string."
        case .targetsMustBeArray:
            "context_menu.add option 'targets' must be a non-empty dense array of target strings."
        case .invalidTarget(let target):
            "Invalid context menu target: \(target)"
        case .actionMustBeFunction:
            "context_menu.add option 'action' must be a function."
        case .readOnlySnapshot:
            "Context menu action snapshot is read-only."
        }
    }
}

@MainActor
final class LuaContextMenuAPI: LuaModuleRegistrable {
    let luaName = "context_menu"

    private let registry: ContextMenuRegistry

    init(registry: ContextMenuRegistry) {
        self.registry = registry
    }

    func pushLuaTable(onto state: LuaPluginState) {
        state.newtable(nrec: 2)
        LuaBridge.addFunction(named: "add", to: state) { [registry] state in
            guard state.type(1) == .table else {
                throw LuaContextMenuAPIError.optionsMustBeTable
            }

            let id = try Self.requiredString(named: "id", from: state, tableIndex: 1)
            let title = try Self.requiredString(named: "title", from: state, tableIndex: 1)
            let targets = try Self.targets(from: state, tableIndex: 1)
            state.rawget(1, utf8Key: "action")
            defer { state.pop() }
            guard state.type(-1) == .function else {
                throw LuaContextMenuAPIError.actionMustBeFunction
            }
            let luaAction = state.ref(index: -1)

            registry.add(id: id, title: title, targets: targets) { snapshot in
                let table = Self.makeReadOnlyTable(for: snapshot, in: state)
                try luaAction.pcall(table, traceback: true)
            }
            return 0
        }
        LuaBridge.addFunction(named: "remove", to: state) { [registry] state in
            let id = try LuaBridge.argument(String.self, from: state, at: 1)
            state.push(registry.remove(id: id))
            return 1
        }
    }

    private static func requiredString(
        named name: String,
        from state: LuaPluginState,
        tableIndex: CInt
    ) throws -> String {
        state.rawget(tableIndex, utf8Key: name)
        defer { state.pop() }
        guard state.type(-1) == .string,
              let value = state.tostring(-1),
              !value.isEmpty else {
            throw LuaContextMenuAPIError.missingString(name)
        }
        return value
    }

    private static func targets(
        from state: LuaPluginState,
        tableIndex: CInt
    ) throws -> Set<ContextMenuTarget> {
        state.rawget(tableIndex, utf8Key: "targets")
        defer { state.pop() }
        guard state.type(-1) == .table,
              let rawLength = state.rawlen(-1),
              rawLength > 0,
              rawLength <= lua_Integer(Int.max) else {
            throw LuaContextMenuAPIError.targetsMustBeArray
        }

        let targetsIndex = state.absindex(-1)
        var values = Array<ContextMenuTarget?>(repeating: nil, count: Int(rawLength))
        var entryCount = 0
        for (keyIndex, valueIndex) in state.pairs(targetsIndex) {
            guard state.type(keyIndex) == .number,
                  let rawKey = state.tointeger(keyIndex),
                  rawKey >= 1,
                  rawKey <= rawLength,
                  state.type(valueIndex) == .string,
                  let rawTarget = state.tostring(valueIndex) else {
                throw LuaContextMenuAPIError.targetsMustBeArray
            }
            guard let target = ContextMenuTarget(rawValue: rawTarget) else {
                throw LuaContextMenuAPIError.invalidTarget(rawTarget)
            }
            let index = Int(rawKey) - 1
            guard values[index] == nil else {
                throw LuaContextMenuAPIError.targetsMustBeArray
            }
            values[index] = target
            entryCount += 1
        }
        guard entryCount == values.count, values.allSatisfy({ $0 != nil }) else {
            throw LuaContextMenuAPIError.targetsMustBeArray
        }
        return Set(values.compactMap { $0 })
    }

    private static func makeReadOnlyTable(
        for snapshot: ContextMenuSnapshot,
        in state: LuaPluginState
    ) -> LuaValue {
        state.newtable(nrec: 12)
        state.rawset(-1, utf8Key: "explorer", value: snapshot.target.explorer)
        state.rawset(-1, utf8Key: "kind", value: snapshot.target.kind)
        state.rawset(-1, utf8Key: "name", value: snapshot.name)
        state.rawset(-1, utf8Key: "path", value: snapshot.path)
        if let value = snapshot.repositoryName {
            state.rawset(-1, utf8Key: "repository_name", value: value)
        }
        if let value = snapshot.repositoryPath {
            state.rawset(-1, utf8Key: "repository_path", value: value)
        }
        if let value = snapshot.gitDirectoryPath {
            state.rawset(-1, utf8Key: "git_directory_path", value: value)
        }
        if let value = snapshot.worktreeName {
            state.rawset(-1, utf8Key: "worktree_name", value: value)
        }
        if let value = snapshot.worktreePath {
            state.rawset(-1, utf8Key: "worktree_path", value: value)
        }
        if let value = snapshot.isMainWorktree {
            state.rawset(-1, utf8Key: "is_main_worktree", value: value)
        }
        let values = state.popref()

        state.newtable()
        let proxy = state.popref()
        state.newtable(nrec: 4)
        state.push(values)
        state.rawset(-2, utf8Key: "__index")
        state.rawset(-1, utf8Key: "__metatable", value: false)
        LuaBridge.addFunction(named: "__newindex", to: state) { _ in
            throw LuaContextMenuAPIError.readOnlySnapshot
        }
        LuaBridge.addFunction(named: "__pairs", to: state) { state in
            state.push(state.globals["next"])
            state.push(values)
            state.pushnil()
            return 3
        }
        proxy.metatable = state.popref()
        return proxy
    }
}
