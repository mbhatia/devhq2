import AppKit
import XCTest
@testable import DevHQ

final class KeyBindingRouterTests: XCTestCase {
    @MainActor
    func testRoutesAvailableCommand() throws {
        let bindings = KeyBindingRegistry()
        try bindings.setDefaultBindings([
            KeyBinding(shortcut: "cmd+x", commandID: "terminal:clear")
        ])
        let manager = CommandManager()
        var executions = 0
        try manager.add(id: "terminal:clear", viewKinds: [.terminal]) { _ in
            executions += 1
        }
        let router = KeyBindingRouter(
            bindings: bindings,
            commandManager: manager,
            context: { CommandContext(view: .terminal) }
        )

        XCTAssertTrue(router.route(keyEvent("x", modifiers: [.command])))
        XCTAssertEqual(executions, 1)
    }

    @MainActor
    func testPassesMappedShortcutThroughWhenCommandIsUnavailable() throws {
        let bindings = KeyBindingRegistry()
        try bindings.setDefaultBindings([
            KeyBinding(shortcut: "ctrl+l", commandID: "terminal:clear")
        ])
        let manager = CommandManager()
        try manager.add(
            id: "terminal:clear",
            viewKinds: [.terminal],
            predicate: { _ in false }
        ) { _ in
            XCTFail("An unavailable command must not execute")
        }
        let router = KeyBindingRouter(
            bindings: bindings,
            commandManager: manager,
            context: { CommandContext(view: .terminal) }
        )

        XCTAssertFalse(router.route(keyEvent("l", modifiers: [.control])))
    }

    @MainActor
    func testPassesMappedShortcutThroughOutsideCommandScope() throws {
        let bindings = KeyBindingRegistry()
        try bindings.setDefaultBindings([
            KeyBinding(shortcut: "cmd+x", commandID: "file:close")
        ])
        let manager = CommandManager()
        try manager.add(id: "file:close", viewKinds: [.document]) { _ in
            XCTFail("An out-of-scope command must not execute")
        }
        let router = KeyBindingRouter(
            bindings: bindings,
            commandManager: manager,
            context: { CommandContext(view: .terminal) }
        )

        XCTAssertFalse(router.route(keyEvent("x", modifiers: [.command])))
    }

    private func keyEvent(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 7 // x; matching uses charactersIgnoringModifiers.
        )!
    }
}

extension KeyBindingRouterTests {
    @MainActor
    func testConsumesActionFailureAndReportsIt() throws {
        enum ActionError: LocalizedError { case failed
            var errorDescription: String? { "Action failed" }
        }
        let bindings = KeyBindingRegistry()
        try bindings.setDefaultBindings([
            KeyBinding(shortcut: "cmd+x", commandID: "terminal:clear")
        ])
        let manager = CommandManager()
        try manager.add(id: "terminal:clear", viewKinds: [.terminal]) { _ in
            throw ActionError.failed
        }
        var reported: Error?
        let router = KeyBindingRouter(
            bindings: bindings,
            commandManager: manager,
            context: { CommandContext(view: .terminal) },
            reportError: { reported = $0 }
        )

        XCTAssertTrue(router.route(keyEvent("x", modifiers: [.command])))
        XCTAssertEqual(reported?.localizedDescription, "Action failed")
    }

    @MainActor
    func testMonitorDoesNotRouteWhenDisabledOrForAnotherWindow() throws {
        let bindings = KeyBindingRegistry()
        try bindings.setDefaultBindings([
            KeyBinding(shortcut: "cmd+x", commandID: "terminal:clear")
        ])
        let manager = CommandManager()
        var executions = 0
        try manager.add(id: "terminal:clear", viewKinds: [.terminal]) { _ in
            executions += 1
        }
        let router = KeyBindingRouter(
            bindings: bindings,
            commandManager: manager,
            context: { CommandContext(view: .terminal) }
        )
        let coordinator = KeyBindingRoutingMonitor.Coordinator(
            router: router,
            isEnabled: false
        )
        let event = keyEvent("x", modifiers: [.command])

        XCTAssertFalse(coordinator.shouldRoute(event, in: nil))
        XCTAssertEqual(executions, 0)

        coordinator.isEnabled = true
        let anotherWindow = NSWindow()
        XCTAssertFalse(coordinator.shouldRoute(event, in: anotherWindow))
        XCTAssertEqual(executions, 0)
    }
}
