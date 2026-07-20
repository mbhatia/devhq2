import AppKit
import XCTest
@testable import DevHQ

final class ApplicationLifecycleTests: XCTestCase {
    @MainActor
    func testApplicationDelegateInvokesTerminationHandler() {
        let delegate = DevHQApplicationDelegate()
        var invocationCount = 0
        delegate.terminationHandler = {
            invocationCount += 1
        }

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertEqual(invocationCount, 1)
    }
}
