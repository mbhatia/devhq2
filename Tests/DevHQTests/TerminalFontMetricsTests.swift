import AppKit
import XCTest
@testable import DevHQ

final class TerminalFontMetricsTests: XCTestCase {
    func testDefaultGridMatchesGhosttyAtStandardAndRetinaScale() {
        let font = TerminalFont.regular(named: "", size: 13)
        for scale: CGFloat in [1, 2] {
            let metrics = TerminalFontMetrics(font: font, scale: scale)
            XCTAssertEqual(metrics.cellWidth, 8)
            XCTAssertEqual(metrics.cellHeight, 17)
            XCTAssertEqual(metrics.baseline, 13)
        }
    }

    func testFractionalFontSizeRoundsInBackingPixels() {
        let font = TerminalFont.regular(named: "", size: 13.5)
        let metrics = TerminalFontMetrics(font: font, scale: 2)
        XCTAssertEqual(metrics.cellWidth, 8)
        XCTAssertEqual(metrics.cellHeight, 18)
        XCTAssertEqual(metrics.baseline, 14)
    }
}
