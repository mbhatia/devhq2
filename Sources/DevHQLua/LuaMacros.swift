@attached(member, names: named(luaName), named(pushLuaTable))
@attached(extension, conformances: LuaModuleRegistrable)
public macro LuaModule(_ name: String) =
    #externalMacro(module: "DevHQLuaMacros", type: "LuaModuleMacro")

@attached(peer, names: arbitrary)
public macro LuaField(_ name: String) =
    #externalMacro(module: "DevHQLuaMacros", type: "LuaFieldMacro")

@attached(peer, names: arbitrary)
public macro LuaFunction(_ name: String) =
    #externalMacro(module: "DevHQLuaMacros", type: "LuaFunctionMacro")
