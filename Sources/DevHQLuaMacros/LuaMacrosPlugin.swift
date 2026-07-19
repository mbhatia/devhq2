import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

private enum LuaMacroError: Error, CustomStringConvertible {
    case declaration(String)

    var description: String {
        switch self {
        case let .declaration(message): message
        }
    }
}

private func luaName(from attribute: AttributeSyntax) throws -> String {
    guard case let .argumentList(arguments) = attribute.arguments,
          let expression = arguments.first?.expression.as(StringLiteralExprSyntax.self),
          expression.segments.count == 1,
          case let .stringSegment(segment)? = expression.segments.first else {
        throw LuaMacroError.declaration("Lua names must be string literals")
    }
    return segment.content.text
}

private func attribute(
    named expectedName: String,
    in attributes: AttributeListSyntax
) -> AttributeSyntax? {
    attributes.lazy
        .compactMap { $0.as(AttributeSyntax.self) }
        .first {
            let name = $0.attributeName.trimmedDescription
            return name == expectedName || name.hasSuffix(".\(expectedName)")
        }
}

private struct LuaRegistration {
    let name: String
    let source: String
}

public struct LuaModuleMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) || declaration.is(ClassDeclSyntax.self) else {
            throw LuaMacroError.declaration("@LuaModule can only be attached to a struct or class")
        }

        let moduleName = try luaName(from: node)
        let access = generatedAccessPrefix(for: declaration)
        let isClass = declaration.is(ClassDeclSyntax.self)
        var fieldRegistrations = [LuaRegistration]()
        var functionRegistrations = [LuaRegistration]()
        var luaNames = Set<String>()

        for member in declaration.memberBlock.members {
            if let variable = member.decl.as(VariableDeclSyntax.self),
               let fieldAttribute = attribute(named: "LuaField", in: variable.attributes) {
                let registration = try fieldRegistration(
                    variable,
                    attribute: fieldAttribute,
                    isClass: isClass
                )
                guard luaNames.insert(registration.name).inserted else {
                    throw LuaMacroError.declaration("Duplicate Lua member name: \(registration.name)")
                }
                fieldRegistrations.append(registration)
            }

            if let function = member.decl.as(FunctionDeclSyntax.self),
               let functionAttribute = attribute(named: "LuaFunction", in: function.attributes) {
                let registration = try functionRegistration(function, attribute: functionAttribute)
                guard luaNames.insert(registration.name).inserted else {
                    throw LuaMacroError.declaration("Duplicate Lua member name: \(registration.name)")
                }
                functionRegistrations.append(registration)
            }
        }

        var body = functionRegistrations.map { "        \($0.source)" }.joined(separator: "\n")
        if !fieldRegistrations.isEmpty {
            let fields = fieldRegistrations
                .map { "            \($0.source)" }
                .joined(separator: ",\n")
            if !body.isEmpty { body += "\n" }
            body += """
                    LuaBridge.addFields([
            \(fields)
                    ], to: state)
            """
        }
        return [
            "\(raw: access)var luaName: String { \(literal: moduleName) }",
            """
            \(raw: access)func pushLuaTable(onto state: LuaPluginState) {
                state.newtable(nrec: \(raw: functionRegistrations.count))
            \(raw: body)
            }
            """
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        [try ExtensionDeclSyntax("extension \(type): LuaModuleRegistrable {}")]
    }

    private static func generatedAccessPrefix(for declaration: some DeclGroupSyntax) -> String {
        for modifier in declaration.modifiers {
            switch modifier.name.text {
            case "open", "public": return "public "
            case "package": return "package "
            default: continue
            }
        }
        return ""
    }

    private static func fieldRegistration(
        _ variable: VariableDeclSyntax,
        attribute: AttributeSyntax,
        isClass: Bool
    ) throws -> LuaRegistration {
        guard variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
            throw LuaMacroError.declaration("@LuaField requires one named stored property")
        }
        let name = try luaName(from: attribute)
        let property = identifier.identifier.text
        let writable = isWritable(variable: variable, binding: binding)
        guard !writable || isClass else {
            throw LuaMacroError.declaration("Writable @LuaField properties require a class")
        }

        let setter: String
        if writable {
            setter = """
            { __luaState in
                            self.\(property) = try LuaBridge.argument(
                                Swift.type(of: self.\(property)),
                                from: __luaState,
                                at: 3
                            )
                            return 0
                        }
            """
        } else {
            setter = "nil"
        }

        return LuaRegistration(
            name: name,
            source: """
            LuaFieldBinding(
                            name: \(name.debugDescription),
                            get: { __luaState in
                                LuaBridge.push(self.\(property), onto: __luaState)
                                return 1
                            },
                            set: \(setter)
                        )
            """
        )
    }

    private static func isWritable(
        variable: VariableDeclSyntax,
        binding: PatternBindingSyntax
    ) -> Bool {
        guard variable.bindingSpecifier.text == "var" else { return false }
        guard let accessorBlock = binding.accessorBlock else { return true }

        switch accessorBlock.accessors {
        case .getter:
            return false
        case let .accessors(accessors):
            let writableAccessors = ["set", "_modify", "willSet", "didSet"]
            return accessors.contains {
                writableAccessors.contains($0.accessorSpecifier.text)
            }
        }
    }

    private static func functionRegistration(
        _ function: FunctionDeclSyntax,
        attribute: AttributeSyntax
    ) throws -> LuaRegistration {
        guard function.signature.effectSpecifiers?.asyncSpecifier == nil else {
            throw LuaMacroError.declaration("@LuaFunction does not support async methods")
        }

        let luaFunctionName = try luaName(from: attribute)
        let swiftFunctionName = function.name.text
        var reads = [String]()
        var arguments = [String]()

        for (offset, parameter) in function.signature.parameterClause.parameters.enumerated() {
            let localName = "__luaArgument\(offset + 1)"
            let type = TypeSyntax(parameter.type)
            reads.append(
                "let \(localName) = try LuaBridge.argument(\(type.trimmedDescription).self, from: __luaState, at: \(offset + 1))"
            )
            let label = parameter.firstName.text
            arguments.append(label == "_" ? localName : "\(label): \(localName)")
        }

        let call = "self.\(swiftFunctionName)(\(arguments.joined(separator: ", ")))"
        let isThrowing = function.signature.effectSpecifiers?.throwsClause != nil
        let tryPrefix = isThrowing ? "try " : ""
        let returnType = function.signature.returnClause?.type.trimmedDescription
        let returnsValue = returnType != nil && returnType != "Void" && returnType != "()"
        let invocation: [String]
        if returnsValue {
            invocation = [
                "let __luaResult = \(tryPrefix)\(call)",
                "LuaBridge.push(__luaResult, onto: __luaState)",
                "return 1"
            ]
        } else {
            invocation = ["\(tryPrefix)\(call)", "return 0"]
        }

        let closureBody = (reads + invocation)
            .map { "    \($0)" }
            .joined(separator: "\n")
        return LuaRegistration(
            name: luaFunctionName,
            source: """
            LuaBridge.addFunction(named: \(luaFunctionName.debugDescription), to: state) { __luaState in
            \(closureBody)
            }
            """
        )
    }
}

public struct LuaFieldMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public struct LuaFunctionMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

@main
struct DevHQLuaPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        LuaModuleMacro.self,
        LuaFieldMacro.self,
        LuaFunctionMacro.self
    ]
}
