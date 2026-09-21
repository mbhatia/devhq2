import AppKit
import CoreText
import XCTest
@testable import DevHQ

final class TerminalFontTests: XCTestCase {
    func testDefaultTerminalFontIsBundledJetBrainsMono() {
        XCTAssertEqual(TerminalFont.regular(named: "", size: 13).fontName, "JetBrainsMono-Regular")
        XCTAssertEqual(TerminalFont.bold(named: "", size: 13).fontName, "JetBrainsMono-Bold")
        XCTAssertEqual(TerminalFont.italic(named: "", size: 13).fontName, "JetBrainsMono-Italic")
        XCTAssertEqual(TerminalFont.boldItalic(named: "", size: 13).fontName, "JetBrainsMono-BoldItalic")
    }

    func testRegisteredFontsComeFromThePackagedResourceBundle() throws {
        let expectedURL = try XCTUnwrap(TerminalFont.bundledFontURL(named: "SymbolsNerdFont-Regular"))
        XCTAssertTrue(expectedURL.path.contains("DevHQ_DevHQ.bundle/Resources/Fonts/"))

        let font = try XCTUnwrap(TerminalFont.nerdSymbolsFont(size: 13))
        let actualURL = try XCTUnwrap(
            CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL
        )
        XCTAssertEqual(actualURL.standardizedFileURL, expectedURL.standardizedFileURL)
    }

    func testBundledNerdFontSupportsPowerlevel10kAndSupplementaryPlaneSymbols() throws {
        let symbols = try XCTUnwrap(TerminalFont.nerdSymbolsFont(size: 13))
        XCTAssertTrue(TerminalFont.supports("\u{E0B0}", in: symbols))
        XCTAssertTrue(TerminalFont.supports("\u{F0001}", in: symbols))
    }

    func testNerdGlyphsUseBundledFallbackWhenPrimaryDoesNotSupportThem() {
        let primary = NSFont(name: "Helvetica", size: 13)!
        XCTAssertEqual(TerminalFont.font(for: "\u{E0B0}", primary: primary).fontName, "SymbolsNF")
        XCTAssertEqual(TerminalFont.font(for: "\u{F0001}", primary: primary).fontName, "SymbolsNF")
    }
}
