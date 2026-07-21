import AppKit
import XCTest
@testable import DevHQ

@MainActor
final class AgentCreationPromptTests: XCTestCase {
    func testFormHasVisibleControlsAndSortedProfiles() throws {
        let form = AgentCreationPrompt.makeForm(profileNames: ["zeta", "alpha"])
        let alert = NSAlert()
        alert.accessoryView = form.view
        let accessoryView = try XCTUnwrap(alert.accessoryView)
        let alertWindow = alert.window
        alertWindow.contentView?.layoutSubtreeIfNeeded()
        alertWindow.displayIfNeeded()

        XCTAssertGreaterThan(accessoryView.frame.width, 0)
        XCTAssertGreaterThan(accessoryView.frame.height, 0)
        XCTAssertGreaterThan(form.profileScrollView.frame.width, 0)
        XCTAssertGreaterThan(form.profileScrollView.frame.height, 0)
        XCTAssertGreaterThan(form.profileTable.frame.width, 0)
        XCTAssertGreaterThan(form.profileTable.frame.height, 0)
        XCTAssertLessThanOrEqual(
            form.profileTable.frame.width,
            form.profileScrollView.contentSize.width
        )
        XCTAssertGreaterThan(form.nameField.frame.width, 0)
        XCTAssertGreaterThan(form.nameField.frame.height, 0)
        XCTAssertFalse(form.profileScrollView.isHidden)
        XCTAssertFalse(form.profileTable.isHidden)
        XCTAssertFalse(form.nameField.isHidden)
        XCTAssertTrue(form.profileScrollView.superview === accessoryView)
        XCTAssertFalse(form.profileScrollView.visibleRect.isEmpty)
        XCTAssertTrue(
            accessoryView.bounds.contains(
                form.profileScrollView.convert(form.profileScrollView.bounds, to: accessoryView)
            )
        )
        XCTAssertEqual(form.profileListController.profileNames, ["alpha", "zeta"])
        XCTAssertEqual(form.profileTable.numberOfRows, 2)
        XCTAssertEqual(form.selectedProfile, "alpha")

        form.profileTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        XCTAssertEqual(form.selectedProfile, "zeta")
    }
}
