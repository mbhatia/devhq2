// swift-tools-version: 5.9

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "DevHQ",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/CodeEditApp/CodeEditSourceEditor.git",
            exact: "0.15.2"
        ),
        .package(
            url: "https://github.com/CodeEditApp/CodeEditLanguages.git",
            exact: "0.1.20"
        ),
        .package(
            url: "https://github.com/CodeEditApp/CodeEditTextView.git",
            exact: "0.12.1"
        ),
        .package(
            url: "https://github.com/ChimeHQ/SwiftTreeSitter.git",
            exact: "0.9.0"
        ),
        .package(
            url: "https://github.com/tomsci/LuaSwift.git",
            exact: "1.0.0"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            exact: "603.0.2"
        ),
        .package(path: "Vendor/CodeEditSymbols")
    ],
    targets: [
        .macro(
            name: "DevHQLuaMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax")
            ]
        ),
        .target(
            name: "DevHQLua",
            dependencies: [
                "DevHQLuaMacros",
                .product(name: "Lua", package: "LuaSwift")
            ]
        ),
        .executableTarget(
            name: "DevHQ",
            dependencies: [
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
                .product(name: "CodeEditTextView", package: "CodeEditTextView"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "Lua", package: "LuaSwift"),
                "DevHQLua"
            ]
        ),
        .testTarget(
            name: "DevHQTests",
            dependencies: ["DevHQ", "DevHQLua"]
        )
    ]
)
