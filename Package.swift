// swift-tools-version: 5.9

import PackageDescription

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
        .package(path: "Vendor/CodeEditSymbols")
    ],
    targets: [
        .executableTarget(
            name: "DevHQ",
            dependencies: [
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
                .product(name: "CodeEditTextView", package: "CodeEditTextView"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter")
            ]
        ),
        .testTarget(
            name: "DevHQTests",
            dependencies: ["DevHQ"]
        )
    ]
)
