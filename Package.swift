// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DevHQ",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/CodeEditApp/CodeEditLanguages.git",
            exact: "0.1.20"
        ),
        .package(
            url: "https://github.com/ChimeHQ/SwiftTreeSitter.git",
            exact: "0.9.0"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter",
            exact: "0.23.2"
        )
    ],
    targets: [
        .executableTarget(
            name: "DevHQ",
            dependencies: [
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitter", package: "tree-sitter")
            ]
        ),
        .testTarget(
            name: "DevHQTests",
            dependencies: ["DevHQ"]
        )
    ]
)
