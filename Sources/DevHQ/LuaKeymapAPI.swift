import DevHQLua
import Foundation
import Lua

private enum LuaKeymapAPIError: LocalizedError {
    case bindingsMustBeTable
    case invalidEntry

    var errorDescription: String? {
        switch self {
        case .bindingsMustBeTable:
            "keymap.add expects a table mapping shortcuts to command identifiers."
        case .invalidEntry:
            "keymap.add entries must map non-empty shortcut strings to non-empty command identifier strings."
        }
    }
}

@MainActor
final class LuaKeymapAPI: LuaModuleRegistrable {
    let luaName = "keymap"
    private let registry: KeyBindingRegistry
    private let commandManager: CommandManager

    init(registry: KeyBindingRegistry, commandManager: CommandManager) {
        self.registry = registry
        self.commandManager = commandManager
    }

    func pushLuaTable(onto state: LuaPluginState) {
        state.newtable(nrec: 1)
        LuaBridge.addFunction(named: "add", to: state) { [registry, commandManager] state in
            guard state.type(1) == .table else {
                throw LuaKeymapAPIError.bindingsMustBeTable
            }
            let overwrite: Bool
            switch state.type(2) {
            case nil, .nil: overwrite = false
            case .boolean: overwrite = state.toboolean(2)
            default: throw LuaBridgeError.invalidArgument(index: 2, expected: "a boolean")
            }

            let tableIndex = state.absindex(1)
            var bindings: [KeyBinding] = []
            for (keyIndex, valueIndex) in state.pairs(tableIndex) {
                guard state.type(keyIndex) == .string,
                      state.type(valueIndex) == .string,
                      let shortcut = state.tostring(keyIndex), !shortcut.isEmpty,
                      let commandID = state.tostring(valueIndex), !commandID.isEmpty else {
                    throw LuaKeymapAPIError.invalidEntry
                }
                guard RegisteredCommand.isValidIdentifier(commandID) else {
                    throw KeyBindingError.invalidCommandIdentifier(commandID)
                }
                guard commandManager.commandsByID[commandID] != nil else {
                    throw KeyBindingError.commandNotRegistered(commandID)
                }
                bindings.append(try KeyBinding(shortcut: shortcut, commandID: commandID))
            }
            try registry.add(bindings, overwrite: overwrite)
            return 0
        }
    }
}
