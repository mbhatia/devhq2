import AppKit
import CoreText
import XCTest
@testable import DevHQ

final class TerminalFontTests: XCTestCase {
    func testPackagedResourceBundleIsFoundUnderAppResources() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let bundleURL = temporaryDirectory.appendingPathComponent("DevHQ_DevHQ.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let infoPlist = [
            "CFBundleIdentifier": "com.example.DevHQResources",
            "CFBundleName": "DevHQResources",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1"
        ] as NSDictionary
        try infoPlist.write(to: bundleURL.appendingPathComponent("Info.plist"))

        let bundle = try XCTUnwrap(DevHQResourceBundle.packagedBundle(resourceURL: temporaryDirectory))
        XCTAssertEqual(bundle.bundleURL.standardizedFileURL, bundleURL.standardizedFileURL)
    }

    func testMissingPackagedResourceDoesNotFallBackToSwiftPMBundle() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let bundleURL = temporaryDirectory.appendingPathComponent("DevHQ_DevHQ.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let infoPlist = [
            "CFBundleIdentifier": "com.example.EmptyDevHQResources",
            "CFBundleName": "EmptyDevHQResources",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1"
        ] as NSDictionary
        try infoPlist.write(to: bundleURL.appendingPathComponent("Info.plist"))

        XCTAssertNil(
            DevHQResourceBundle.url(
                forResource: "JetBrainsMono-Regular",
                withExtension: "ttf",
                subdirectory: "Fonts",
                packagedResourceURL: temporaryDirectory
            )
        )
    }

    func testMissingPackagedBundleDoesNotUseSwiftPMFallbackInApp() {
        XCTAssertNil(
            DevHQResourceBundle.url(
                forResource: "JetBrainsMono-Regular",
                withExtension: "ttf",
                subdirectory: "Fonts",
                packagedResourceURL: nil,
                mainBundleURL: URL(fileURLWithPath: "/Applications/DevHQ.app", isDirectory: true)
            )
        )
    }

    func testBundledResourceProbeFailsWhenPackagedFontsAreMissing() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let bundleURL = temporaryDirectory.appendingPathComponent("DevHQ_DevHQ.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let infoPlist = [
            "CFBundleIdentifier": "com.example.EmptyDevHQResources",
            "CFBundleName": "EmptyDevHQResources",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1"
        ] as NSDictionary
        try infoPlist.write(to: bundleURL.appendingPathComponent("Info.plist"))

        var errors: [String] = []
        XCTAssertEqual(
            BundledResourcesCLI.run(
                packagedResourceURL: temporaryDirectory,
                output: { _ in },
                errorOutput: { errors.append($0) }
            ),
            1
        )
        XCTAssertEqual(errors, ["devhq: bundled terminal fonts could not be resolved from the app resources"])
    }

    func testDefaultTerminalFontIsBundledJetBrainsMono() {
        XCTAssertEqual(TerminalFont.regular(named: "", size: 13).fontName, "JetBrainsMono-Regular")
        XCTAssertEqual(TerminalFont.bold(named: "", size: 13).fontName, "JetBrainsMono-Bold")
        XCTAssertEqual(TerminalFont.italic(named: "", size: 13).fontName, "JetBrainsMono-Italic")
        XCTAssertEqual(TerminalFont.boldItalic(named: "", size: 13).fontName, "JetBrainsMono-BoldItalic")
    }

    func testRegisteredFontsComeFromThePackagedResourceBundle() throws {
        let resourceBundle = Bundle.module
        let fontURLs = try XCTUnwrap(TerminalFont.verifiedBundledFontURLs(in: resourceBundle))
        XCTAssertEqual(fontURLs.count, 5)
        for url in fontURLs {
            XCTAssertTrue(url.path.contains("DevHQ_DevHQ.bundle/Resources/Fonts/"))
        }
    }

    func testBundledNerdFontSupportsPowerlevel10kAndSupplementaryPlaneSymbols() throws {
        let symbols = try XCTUnwrap(TerminalFont.nerdSymbolsFont(size: 13))
        XCTAssertTrue(TerminalFont.supports("\u{E0B0}", in: symbols))
        XCTAssertTrue(TerminalFont.supports("\u{F0001}", in: symbols))
    }


}
