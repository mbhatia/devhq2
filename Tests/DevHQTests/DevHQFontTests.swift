import AppKit
import XCTest
@testable import DevHQ

final class DevHQFontTests: XCTestCase {
    func testDefaultUIFontUsesSystemRegular() {
        let size: CGFloat = 17

        let font = DevHQFont.uiNSFont(named: "", size: size)
        let systemFont = NSFont.systemFont(ofSize: size, weight: .regular)

        XCTAssertEqual(font.fontName, systemFont.fontName)
        XCTAssertEqual(font.pointSize, systemFont.pointSize)
    }

    func testExplicitUIFontOverrideRemainsSupported() throws {
        let size: CGFloat = 15
        let override = try XCTUnwrap(NSFont(name: "Helvetica", size: size))

        let font = DevHQFont.uiNSFont(named: override.fontName, size: size)

        XCTAssertEqual(font.fontName, override.fontName)
        XCTAssertEqual(font.pointSize, size)
    }

    func testBundledCodeFontRemainsMartianMono() {
        XCTAssertEqual(DevHQFont.codeFont(size: 13).fontName, "MartianMonoNFM")
    }
}
