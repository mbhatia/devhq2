import Foundation
import Lua

public typealias LuaPluginState = LuaState

@MainActor
public protocol LuaModuleRegistrable {
    var luaName: String { get }
    func pushLuaTable(onto state: LuaPluginState)
}

public protocol LuaPluginValue: Pushable {
    static func read(from state: LuaPluginState, at index: CInt) throws -> Self
}

public enum LuaBridgeError: LocalizedError {
    case invalidArgument(index: CInt, expected: String)
    case readOnlyField(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidArgument(index, expected):
            "Lua argument \(index) must be \(expected)"
        case let .readOnlyField(name):
            "Lua field '\(name)' is read-only"
        }
    }
}

public struct LuaFieldBinding {
    public let name: String
    fileprivate let get: LuaClosure
    fileprivate let set: LuaClosure?

    public init(
        name: String,
        get: @escaping LuaClosure,
        set: LuaClosure? = nil
    ) {
        self.name = name
        self.get = get
        self.set = set
    }
}

public enum LuaBridge {
    public static func addFunction(
        named name: String,
        to state: LuaPluginState,
        _ body: @escaping LuaClosure
    ) {
        state.push(body)
        state.rawset(-2, utf8Key: name)
    }

    public static func addFields(
        _ fields: [LuaFieldBinding],
        to state: LuaPluginState
    ) {
        guard !fields.isEmpty else { return }

        let fieldsByName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
        let table = state.popref()
        state.newtable(nrec: 2)
        addFunction(named: "__index", to: state) { state in
            guard let name = state.tostring(2), let field = fieldsByName[name] else {
                state.pushnil()
                return 1
            }
            return try field.get(state)
        }
        addFunction(named: "__newindex", to: state) { state in
            guard let name = state.tostring(2), let field = fieldsByName[name] else {
                state.push(index: 2)
                state.push(index: 3)
                state.rawset(1)
                return 0
            }
            guard let set = field.set else {
                throw LuaBridgeError.readOnlyField(name)
            }
            return try set(state)
        }
        let metatable = state.popref()
        table.metatable = metatable
        state.push(table)
    }

    public static func argument<Value: LuaPluginValue>(
        _ type: Value.Type,
        from state: LuaPluginState,
        at index: CInt
    ) throws -> Value {
        try Value.read(from: state, at: index)
    }

    public static func push<Value: Pushable>(_ value: Value, onto state: LuaPluginState) {
        state.push(value)
    }
}

extension String: LuaPluginValue {
    public static func read(from state: LuaPluginState, at index: CInt) throws -> String {
        guard let value = state.tostring(index) else {
            throw LuaBridgeError.invalidArgument(index: index, expected: "a string")
        }
        return value
    }
}

extension Bool: LuaPluginValue {
    public static func read(from state: LuaPluginState, at index: CInt) throws -> Bool {
        guard state.type(index) == .boolean else {
            throw LuaBridgeError.invalidArgument(index: index, expected: "a boolean")
        }
        return state.toboolean(index)
    }
}

extension Double: LuaPluginValue {
    public static func read(from state: LuaPluginState, at index: CInt) throws -> Double {
        guard let value = state.tonumber(index) else {
            throw LuaBridgeError.invalidArgument(index: index, expected: "a number")
        }
        return value
    }
}

extension Int: LuaPluginValue {
    public static func read(from state: LuaPluginState, at index: CInt) throws -> Int {
        guard let value = state.tointeger(index) else {
            throw LuaBridgeError.invalidArgument(index: index, expected: "an integer")
        }
        return Int(value)
    }
}
