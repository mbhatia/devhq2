import AppKit
import XCTest
@testable import DevHQ

final class KeyBindingTests: XCTestCase {
    @MainActor
    func testCanonicalizesAliasesAndFormatsLabel() throws {
        let binding = try KeyBinding(shortcut: "command+alt+shift+p", commandID: "palette:show")

        XCTAssertEqual(binding.shortcut, "cmd+option+shift+p")
        XCTAssertEqual(binding.displayLabel, "⌥⇧⌘P")
    }

    @MainActor
    func testAdditionalBindingPreservesExistingBindingAndConflictIsAtomic() throws {
        let registry = KeyBindingRegistry()
        try registry.add([KeyBinding(shortcut: "cmd+p", commandID: "palette:show")])
        try registry.add([KeyBinding(shortcut: "cmd+shift+p", commandID: "palette:show")])
        XCTAssertNil(registry.binding(for: "other:command"))
        XCTAssertEqual(registry.displayLabel(for: "palette:show"), "⌘P, ⇧⌘P")

        XCTAssertThrowsError(
            try registry.add([KeyBinding(shortcut: "cmd+shift+p", commandID: "other:command")])
        ) { error in
            XCTAssertEqual(
                error as? KeyBindingError,
                .conflictingShortcut(shortcut: "cmd+shift+p", commandID: "palette:show")
            )
        }
        XCTAssertEqual(registry.displayLabel(for: "palette:show"), "⌘P, ⇧⌘P")
    }

    @MainActor
    func testOverwriteTakesShortcutFromExistingCommand() throws {
        let registry = KeyBindingRegistry()
        try registry.add([KeyBinding(shortcut: "cmd+p", commandID: "palette:show")])
        try registry.add([KeyBinding(shortcut: "cmd+p", commandID: "other:command")], overwrite: true)

        XCTAssertNil(registry.binding(for: "palette:show"))
        XCTAssertEqual(registry.binding(for: "other:command")?.shortcut, "cmd+p")
    }

    @MainActor
    func testMatchesControlAndShiftedPunctuationEvents() throws {
        let registry = KeyBindingRegistry()
        try registry.add([
            KeyBinding(shortcut: "ctrl+shift+1", commandID: "test:one"),
            KeyBinding(shortcut: "ctrl+`", commandID: "test:tick")
        ])

        XCTAssertEqual(
            registry.command(for: event(
                characters: "!", ignoringModifiers: "1", modifiers: [.control, .shift], keyCode: 18
            )),
            "test:one"
        )
        XCTAssertEqual(registry.command(for: event(characters: "`", modifiers: [.control], keyCode: 50)), "test:tick")
        try registry.add([KeyBinding(shortcut: "cmd+enter", commandID: "test:enter")])
        XCTAssertEqual(registry.command(for: event(characters: "", modifiers: [.command], keyCode: 76)), "test:enter")
    }

    @MainActor
    func testRejectsUnmodifiedAndInvalidShortcuts() {
        XCTAssertThrowsError(try KeyBinding(shortcut: "p", commandID: "test:command"))
        XCTAssertThrowsError(try KeyBinding(shortcut: "cmd+unknown", commandID: "test:command"))
        XCTAssertThrowsError(try KeyBinding(shortcut: "cmd+shift+!", commandID: "test:command")) { error in
            XCTAssertEqual(
                error as? KeyBindingError,
                .shiftedPunctuationShortcut("cmd+shift+!")
            )
        }
    }

    private func event(
        characters: String,
        ignoringModifiers: String? = nil,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers ?? characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
