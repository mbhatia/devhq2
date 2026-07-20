import AppKit
import XCTest
@testable import DevHQ

final class WorkspaceSplitViewRestorerTests: XCTestCase {
    func testDividerPositionMathIncludesFirstDividerThickness() {
        XCTAssertEqual(
            WorkspaceDividerPositions.make(
                origin: 10,
                worktreeExplorerWidth: 312,
                fileExplorerWidth: 418,
                dividerThickness: 1
            ),
            WorkspaceDividerPositions(first: 322, second: 741)
        )
    }

    @MainActor
    func testRestoresBothWidthsInThreePaneSplitView() {
        let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 700))
        splitView.isVertical = true
        for _ in 0 ..< 3 {
            splitView.addArrangedSubview(NSView())
        }
        splitView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            WorkspaceSplitViewRestorer.restoreWidths(
                in: splitView,
                worktreeExplorerWidth: 312,
                fileExplorerWidth: 418
            )
        )

        XCTAssertEqual(splitView.arrangedSubviews[0].frame.width, 312, accuracy: 0.5)
        XCTAssertEqual(splitView.arrangedSubviews[1].frame.width, 418, accuracy: 0.5)
    }

    @MainActor
    func testRejectsSplitViewWithoutThreePanes() {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.addArrangedSubview(NSView())
        splitView.addArrangedSubview(NSView())

        XCTAssertFalse(
            WorkspaceSplitViewRestorer.restoreWidths(
                in: splitView,
                worktreeExplorerWidth: 312,
                fileExplorerWidth: 418
            )
        )
    }

}
