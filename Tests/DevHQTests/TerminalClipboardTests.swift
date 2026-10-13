import AppKit
import XCTest
@testable import DevHQ

final class TerminalClipboardTests: XCTestCase {
    @MainActor
    func testStandardCopyResponderActionCopiesSelectedTerminalText() throws {
        let originalClipboard = snapshotClipboard()
        defer { restoreClipboard(originalClipboard) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try TerminalSession(
            rootURL: root,
            command: ["/bin/sh", "-c", "printf 'hello'"]
        )
        defer { session.close() }

        let deadline = Date().addingTimeInterval(3)
        while !session.snapshot.cells.flatMap({ $0 }).map(\.text).joined().contains("hello"),
              Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertTrue(session.snapshot.cells.flatMap({ $0 }).map(\.text).joined().contains("hello"))

        let terminal = NativeTerminalView(session: session, fontName: "Menlo")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 408),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        terminal.frame = window.contentView!.bounds
        window.contentView?.addSubview(terminal)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        XCTAssertTrue(window.firstResponder === terminal)
        defer { window.orderOut(nil) }

        let down = terminalPointEvent(.leftMouseDown, column: 1, terminal: terminal, window: window)
        let drag = terminalPointEvent(.leftMouseDragged, column: 3, terminal: terminal, window: window)
        terminal.mouseDown(with: down)
        terminal.mouseDragged(with: drag)

        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSApplication.shared.sendAction(#selector(NativeTerminalView.copy(_:)), to: terminal, from: nil))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ell")
    }

    @MainActor
    func testStandardCopyResponderActionDoesNotChangeClipboardWithoutSelection() throws {
        let originalClipboard = snapshotClipboard()
        defer { restoreClipboard(originalClipboard) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try TerminalSession(rootURL: root, command: ["/bin/sleep", "5"])
        defer { session.close() }

        let terminal = NativeTerminalView(session: session, fontName: "Menlo")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 408),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        terminal.frame = window.contentView!.bounds
        window.contentView?.addSubview(terminal)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        XCTAssertTrue(window.firstResponder === terminal)
        defer { window.orderOut(nil) }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("keep", forType: .string)
        XCTAssertTrue(NSApplication.shared.sendAction(#selector(NativeTerminalView.copy(_:)), to: terminal, from: nil))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "keep")
    }

    @MainActor
    private func terminalPointEvent(
        _ type: NSEvent.EventType,
        column: Int,
        terminal: NativeTerminalView,
        window: NSWindow
    ) -> NSEvent {
        let pointInTerminal = NSPoint(
            x: (CGFloat(column) + 0.5) * terminal.cellWidth,
            y: terminal.cellHeight / 2
        )
        let pointInWindow = terminal.convert(pointInTerminal, to: nil)
        return NSEvent.mouseEvent(
            with: type,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    @MainActor
    private func snapshotClipboard() -> [[(NSPasteboard.PasteboardType, Data)]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        }
    }

    @MainActor
    private func restoreClipboard(_ contents: [[(NSPasteboard.PasteboardType, Data)]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = contents.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
