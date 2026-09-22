import AppKit
import XCTest
@testable import DevHQ

final class KeyBindingIntegrationTests: XCTestCase {
    @MainActor
    func testLuaConfiguredShortcutIsConsumedBeforeTerminalInputWhileTypingPassesThrough() throws {
        let configurationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configurationDirectory) }
        try """
        local command = require "command"
        local keymap = require "keymap"
        local devhq = require "devhq"
        command.add("lua:terminal-action", nil, function()
          devhq.window.theme = "dark"
        end)
        keymap.add { ["cmd+shift+k"] = "lua:terminal-action" }
        """.write(
            to: configurationDirectory.appendingPathComponent("init.lua"),
            atomically: true,
            encoding: .utf8
        )

        let settings = EditorSettings()
        let bindings = KeyBindingRegistry()
        let commands = CommandManager()
        let host = LuaPluginHost(
            settings: settings,
            configDirectory: configurationDirectory,
            commandManager: commands,
            keyBindingRegistry: bindings
        )
        host.loadUserConfiguration()
        XCTAssertNil(settings.pluginError)

        let session = try TerminalSession(rootURL: configurationDirectory, command: ["/bin/cat"])
        defer { session.close() }
        let terminal = NativeTerminalView(session: session, fontName: "Menlo")
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let window = NSWindow(
            contentRect: rootView.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = rootView
        terminal.frame = rootView.bounds
        rootView.addSubview(terminal)

        let router = KeyBindingRouter(
            bindings: bindings,
            commandManager: commands,
            context: { CommandContext(view: .terminal, terminalID: session.id) }
        )
        let coordinator = KeyBindingRoutingMonitor.Coordinator(router: router, isEnabled: true)
        let monitorView = NSView(frame: .zero)
        rootView.addSubview(monitorView)
        coordinator.install(for: monitorView)
        defer {
            coordinator.uninstall()
            window.orderOut(nil)
        }

        let application = NSApplication.shared
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        XCTAssertTrue(window.firstResponder === terminal)

        var terminalInputCount = 0
        session.onUserInput = { terminalInputCount += 1 }

        application.sendEvent(keyEvent("k", modifiers: [.command, .shift], window: window))
        XCTAssertEqual(settings.windowTheme, .dark)
        XCTAssertEqual(terminalInputCount, 0, "The routed shortcut must not reach the terminal PTY")

        application.sendEvent(keyEvent("a", modifiers: [], window: window))
        XCTAssertEqual(terminalInputCount, 1, "Unbound typing must reach the terminal")
    }

    @MainActor
    private func keyEvent(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags,
        window: NSWindow
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: characters == "k" ? 40 : 0
        )!
    }
}
