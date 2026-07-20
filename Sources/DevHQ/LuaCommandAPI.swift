import DevHQLua
import Foundation
import Lua

private enum LuaCommandAPIError: LocalizedError {
    case invalidViewKind(String)
    case predicateMustReturnBoolean(String)

    var errorDescription: String? {
        switch self {
        case let .invalidViewKind(value):
            "Invalid command view kind: \(value)"
        case let .predicateMustReturnBoolean(id):
            "Command predicate for \(id) must return a boolean"
        }
    }
}

@MainActor
final class LuaCommandAPI: LuaModuleRegistrable {
    let luaName = "command"

    private let commandManager: CommandManager

    init(commandManager: CommandManager) {
        self.commandManager = commandManager
    }

    func pushLuaTable(onto state: LuaPluginState) {
        state.newtable(nrec: 2)
        LuaBridge.addFunction(named: "add", to: state) { [commandManager] state in
            let id = try LuaBridge.argument(String.self, from: state, at: 1)
            guard state.type(3) == .function else {
                throw LuaBridgeError.invalidArgument(index: 3, expected: "a function")
            }

            let action = state.ref(index: 3)
            let viewKinds: Set<CommandViewKind>
            let predicate: RegisteredCommand.Predicate

            switch state.type(2) {
            case nil, .nil:
                viewKinds = Set(CommandViewKind.allCases)
                predicate = { _ in true }
            case .string:
                let value = try LuaBridge.argument(String.self, from: state, at: 2)
                guard let viewKind = CommandViewKind(rawValue: value) else {
                    throw LuaCommandAPIError.invalidViewKind(value)
                }
                viewKinds = [viewKind]
                predicate = { _ in true }
            case .function:
                let luaPredicate = state.ref(index: 2)
                viewKinds = Set(CommandViewKind.allCases)
                predicate = { context in
                    let result = try luaPredicate.pcall(context.view.rawValue)
                    guard result.type == .boolean else {
                        throw LuaCommandAPIError.predicateMustReturnBoolean(id)
                    }
                    return result.toboolean()
                }
            default:
                throw LuaBridgeError.invalidArgument(
                    index: 2,
                    expected: "nil, a view-kind string, or a function"
                )
            }

            try commandManager.add(
                id: id,
                viewKinds: viewKinds,
                predicate: predicate
            ) { _ in
                try action.pcall(nargs: 0, nret: 0)
            }
            return 0
        }
        LuaBridge.addFunction(named: "remove", to: state) { [commandManager] state in
            let id = try LuaBridge.argument(String.self, from: state, at: 1)
            state.push(commandManager.remove(id: id))
            return 1
        }
    }
}
