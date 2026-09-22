import CoreGraphics
import XCTest
@testable import DevHQ

final class TerminalGlyphLayoutTests: XCTestCase {
    private let cell = CGRect(x: 10, y: 20, width: 8, height: 20)

    func testConstrainedNerdIconIncludesAppleAndFolderButNotPowerline() {
        XCTAssertTrue(TerminalGlyphLayout.isConstrainedNerdIcon("\u{E711}"))
        XCTAssertTrue(TerminalGlyphLayout.isConstrainedNerdIcon("\u{F07B}"))
        XCTAssertTrue(TerminalGlyphLayout.isConstrainedNerdIcon("\u{F418}"))
        XCTAssertTrue(TerminalGlyphLayout.isConstrainedNerdIcon("\u{F0001}"))
        XCTAssertFalse(TerminalGlyphLayout.isConstrainedNerdIcon("\u{E0B0}"))
        XCTAssertFalse(TerminalGlyphLayout.isConstrainedNerdIcon("A"))
    }

    func testOneCellIconFitsUniformlyAndCentersInIconArea() throws {
        let layout = try XCTUnwrap(TerminalGlyphLayout.layout(
            glyphBounds: CGRect(x: 1, y: -10, width: 12, height: 10),
            cellRect: cell,
            faceRect: cell,
            faceWidth: 8,
            availableCells: 1,
            singleIconHeight: 13,
            iconHeight: 13
        ))

        XCTAssertEqual(layout.scale, 8 / 12, accuracy: 0.0001)
        XCTAssertEqual(layout.inkRect.width, 8, accuracy: 0.0001)
        XCTAssertEqual(layout.inkRect.height, 10 * (8 / 12), accuracy: 0.0001)
        XCTAssertEqual(layout.inkRect.midX, cell.midX, accuracy: 0.0001)
        XCTAssertEqual(layout.inkRect.midY, cell.midY, accuracy: 0.0001)
    }

    func testBlankFollowingCellAllowsWidthWithoutUpscalingOrMovingFromFirstCell() throws {
        let layout = try XCTUnwrap(TerminalGlyphLayout.layout(
            glyphBounds: CGRect(x: 0, y: -10, width: 12, height: 10),
            cellRect: cell,
            faceRect: cell,
            faceWidth: 8,
            availableCells: 2,
            singleIconHeight: 13,
            iconHeight: 13
        ))

        XCTAssertEqual(layout.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(layout.inkRect.width, 12, accuracy: 0.0001)
        XCTAssertEqual(layout.inkRect.minX, cell.minX, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(layout.inkRect.maxX, cell.maxX + cell.width)
    }

    func testNonBlankOrEndCellKeepsIconToOneCell() throws {
        let layout = try XCTUnwrap(TerminalGlyphLayout.layout(
            glyphBounds: CGRect(x: 0, y: -10, width: 12, height: 10),
            cellRect: cell,
            faceRect: cell,
            faceWidth: 8,
            availableCells: 0,
            singleIconHeight: 13,
            iconHeight: 13
        ))

        XCTAssertEqual(layout.scale, 8 / 12, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(layout.inkRect.maxX, cell.maxX + 0.0001)
    }
}
