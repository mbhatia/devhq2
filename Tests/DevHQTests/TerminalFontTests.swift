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
                forResource: "MartianMonoNerdFontMono-Regular",
                withExtension: "ttf",
                subdirectory: "Fonts",
                packagedResourceURL: temporaryDirectory
            )
        )
    }

    func testMissingPackagedBundleDoesNotUseSwiftPMFallbackInApp() {
        XCTAssertNil(
            DevHQResourceBundle.url(
                forResource: "MartianMonoNerdFontMono-Regular",
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

    func testDefaultTerminalFontUsesGhosttyJetBrainsMonoFaces() {
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
            XCTAssertTrue(url.path.hasPrefix(resourceBundle.bundleURL.path + "/"))
            XCTAssertTrue(url.path.contains("/Resources/Fonts/"))
        }
    }

    func testCopiedResourcesResolveInsideXcodeStyleBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("DevHQ_DevHQ.bundle", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources/Resources", isDirectory: true)
        let fonts = resources.appendingPathComponent("Fonts", isDirectory: true)
        let terminfo = resources.appendingPathComponent("terminfo", isDirectory: true)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: terminfo, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.example.NestedResources", "CFBundlePackageType": "BNDL"] as NSDictionary)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let fontURL = fonts.appendingPathComponent("Example.ttf")
        try Data().write(to: fontURL)

        XCTAssertEqual(DevHQResourceBundle.url(forResource: "Example", withExtension: "ttf", subdirectory: "Fonts", packagedResourceURL: root), fontURL)
        XCTAssertEqual(DevHQResourceBundle.directoryURL(named: "terminfo", packagedResourceURL: root)?.standardizedFileURL, terminfo.standardizedFileURL)
    }

    func testNerdFontFallbackMapsPromptIconsAcrossAllStylesAndSupplementaryPUA() throws {
        let glyphs = ["\u{F179}", "\u{F07C}", "\u{F126}", "\u{E0A0}", "\u{E0B0}", "\u{E0B1}", "\u{E0B2}", "\u{E0B3}", "\u{E0BA}", "\u{E0BC}", "\u{E0BD}", "\u{F0001}"]
        let styles = [
            TerminalFont.regular(named: "", size: 13),
            TerminalFont.bold(named: "", size: 13),
            TerminalFont.italic(named: "", size: 13),
            TerminalFont.boldItalic(named: "", size: 13)
        ]
        XCTAssertTrue(hasMappedGlyph("\u{F0001}", in: try XCTUnwrap(NSFont(name: "SymbolsNF", size: 13))))
        for primary in styles {
            for glyph in glyphs {
                let resolved = TerminalFont.font(for: glyph, primary: primary)
                XCTAssertTrue(hasMappedGlyph(glyph, in: resolved), "Missing mapped glyph U+\(String(glyph.unicodeScalars.first!.value, radix: 16))")
            }
        }
    }

    func testCustomMenloGetsSymbolFallbackButNerdOverrideIsPreserved() {
        let icon = "\u{F179}"
        let menlo = TerminalFont.regular(named: "Menlo", size: 13)
        XCTAssertEqual(TerminalFont.font(for: icon, primary: menlo).fontName, "SymbolsNF")

        let nerdOverride = TerminalFont.regular(named: "MartianMonoNFM", size: 13)
        XCTAssertTrue(hasMappedGlyph(icon, in: nerdOverride))
        XCTAssertEqual(TerminalFont.font(for: icon, primary: nerdOverride).fontName, nerdOverride.fontName)
    }

    private func hasMappedGlyph(_ text: String, in font: NSFont) -> Bool {
        var characters = Array(text.utf16)
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        guard CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count) else { return false }
        return glyphs[0] != 0
    }

}
