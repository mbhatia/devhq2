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
        .target(
            name: "CLibgit2",
            dependencies: ["libgit2", "libssh2", "libssl", "libcrypto"],
            path: "Sources/DevHQ/CLibgit2"
        ),
        .executableTarget(
            name: "DevHQ",
            dependencies: [
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
                .product(name: "CodeEditTextView", package: "CodeEditTextView"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "Lua", package: "LuaSwift"),
                "CLibgit2",
                "DevHQLua"
            ],
            path: "Sources/DevHQ",
            exclude: ["CLibgit2"]
        ),
        .testTarget(
            name: "DevHQTests",
            dependencies: ["DevHQ", "DevHQLua"]
        ),
        .binaryTarget(
            name: "libgit2",
            url: "https://raw.githubusercontent.com/swift-developer-tools/swift-libgit2/1.0.1/swift-libgit2-base/lib/libgit2.zip",
            checksum: "ce79659d81426d6ebfd49cb05a37b8792a8ea459276ed1fb69f09ca0b501f20b"
        ),
        .binaryTarget(
            name: "libssh2",
            url: "https://raw.githubusercontent.com/swift-developer-tools/swift-libgit2/1.0.1/swift-libgit2-base/lib/libssh2.zip",
            checksum: "728ec284f5fb27ea71da85027e29314eb7d8aa6022ccee55e4f9f69ddec9bd74"
        ),
        .binaryTarget(
            name: "libssl",
            url: "https://raw.githubusercontent.com/swift-developer-tools/swift-libgit2/1.0.1/swift-libgit2-base/lib/libssl.zip",
            checksum: "168aa8d3f299ab27bf8d3930f87f5b5883f3dfc3090e389c7bd030ede3052582"
        ),
        .binaryTarget(
            name: "libcrypto",
            url: "https://raw.githubusercontent.com/swift-developer-tools/swift-libgit2/1.0.1/swift-libgit2-base/lib/libcrypto.zip",
            checksum: "c3bc28f0a252b60189e931540e1efaad7e3479e69b3fa9acf1d134835f9a1fb7"
        )
    ]
)
