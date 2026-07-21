import AppKit
import CoreText
import SwiftUI

struct TerminalView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeNSView(context: Context) -> NativeTerminalView {
        NativeTerminalView(session: session)
    }

    func updateNSView(_ view: NativeTerminalView, context: Context) {
        view.session = session
        view.snapshot = session.snapshot
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: NativeTerminalView, coordinator: Void) {
        view.session.setFocused(false)
    }
}

final class NativeTerminalView: NSView, NSTextInputClient {
    var session: TerminalSession
    var snapshot: TerminalRenderSnapshot
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private lazy var italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    private(set) var cellWidth: CGFloat = 8
    private(set) var cellHeight: CGFloat = 17
    private var baseline: CGFloat = 13
    private var markedText = NSMutableAttributedString()
    private var selectionStart: (column: Int, row: Int)?
    private var selectionEnd: (column: Int, row: Int)?
    private var contextMenuLinkPoint: (column: Int, row: Int)?
    private var applicationMouseTracking = false

    init(session: TerminalSession) {
        self.session = session
        snapshot = session.snapshot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        layer?.masksToBounds = true
        let ctFont = font as CTFont
        var glyph = CTFontGetGlyphWithName(ctFont, "M" as CFString)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        cellWidth = ceil(advance.width)
        baseline = ceil(CTFontGetAscent(ctFont))
        cellHeight = ceil(
            CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont) + 2
        )
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func becomeFirstResponder() -> Bool {
        session.setFocused(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        session.setFocused(false)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSize()
    }

    private func updateSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let columns = max(1, Int(bounds.width / cellWidth))
        let rows = max(1, Int(bounds.height / cellHeight))
        session.resize(
            columns: columns,
            rows: rows,
            pixelWidth: Int(bounds.width),
            pixelHeight: Int(bounds.height)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for row in snapshot.cells.indices {
            let y = CGFloat(row) * cellHeight
            if y > dirtyRect.maxY || y + cellHeight < dirtyRect.minY { continue }
            for column in snapshot.cells[row].indices {
                let cell = snapshot.cells[row][column]
                let rect = CGRect(
                    x: CGFloat(column) * cellWidth,
                    y: y,
                    width: cellWidth * CGFloat(max(1, cell.width)),
                    height: cellHeight
                )
                let selected = isSelected(column: column, row: row)
                let background = selected
                    ? NSColor.selectedTextBackgroundColor
                    : (cell.inverse ? cell.foreground?.nsColor : cell.background?.nsColor)
                if let background {
                    background.setFill()
                    context.fill(rect)
                }
                guard !cell.text.isEmpty, cell.text != " " else { continue }
                let foreground = selected
                    ? NSColor.selectedTextColor
                    : (cell.inverse ? cell.background?.nsColor : cell.foreground?.nsColor)
                        ?? NSColor(calibratedWhite: 0.88, alpha: 1)
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: cell.bold ? boldFont : (cell.italic ? italicFont : font),
                    .foregroundColor: foreground
                ]
                if cell.underline || cell.hyperlink != nil {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if cell.strikethrough {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                NSAttributedString(string: cell.text, attributes: attributes).draw(
                    at: CGPoint(x: rect.minX, y: y + baseline - font.ascender)
                )
            }
        }
        drawCursor(context)
    }

    private func drawCursor(_ context: CGContext) {
        guard snapshot.cursorVisible,
              snapshot.cursorRow >= 0,
              snapshot.cursorRow < snapshot.rows else { return }
        let x = CGFloat(snapshot.cursorColumn) * cellWidth
        let y = CGFloat(snapshot.cursorRow) * cellHeight
        NSColor.controlAccentColor.setFill()
        let rect: CGRect
        switch snapshot.cursorStyle {
        case .block: rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
        case .bar: rect = CGRect(x: x, y: y, width: 2, height: cellHeight)
        case .underline: rect = CGRect(x: x, y: y + cellHeight - 2, width: cellWidth, height: 2)
        }
        context.fill(rect)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "c" { copySelection(); return }
            if event.charactersIgnoringModifiers?.lowercased() == "v" { pasteFromClipboard(); return }
            super.keyDown(with: event)
            return
        }
        if flags.contains(.control), let character = event.charactersIgnoringModifiers?.lowercased().first,
           let ascii = character.asciiValue, ascii >= 0x40, ascii <= 0x7f {
            session.send(bytes: [ascii & 0x1f])
            return
        }
        switch event.keyCode {
        case 126: session.sendSpecialKey(.up, modifiers: flags)
        case 125: session.sendSpecialKey(.down, modifiers: flags)
        case 124: session.sendSpecialKey(.right, modifiers: flags)
        case 123: session.sendSpecialKey(.left, modifiers: flags)
        case 115: session.sendSpecialKey(.home, modifiers: flags)
        case 119: session.sendSpecialKey(.end, modifiers: flags)
        case 116: session.sendSpecialKey(.pageUp, modifiers: flags)
        case 121: session.sendSpecialKey(.pageDown, modifiers: flags)
        case 117: session.sendSpecialKey(.delete, modifiers: flags)
        case 51: session.sendSpecialKey(.backspace, modifiers: flags)
        case 48: session.sendSpecialKey(.tab, modifiers: flags)
        case 36, 76: session.sendSpecialKey(.returnKey, modifiers: flags)
        case 53: session.sendSpecialKey(.escape, modifiers: flags)
        default: interpretKeyEvents([event])
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command),
           let gridPoint = gridPointIfInside(for: point),
           session.openHyperlink(at: gridPoint) {
            applicationMouseTracking = false
            selectionStart = nil
            selectionEnd = nil
            needsDisplay = true
            return
        }
        if !event.modifierFlags.contains(.shift), session.sendMouse(
            action: 0,
            button: 1,
            modifiers: event.modifierFlags,
            x: point.x,
            y: point.y
        ) {
            applicationMouseTracking = true
            return
        }
        applicationMouseTracking = false
        selectionStart = gridPoint(for: point)
        selectionEnd = selectionStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if applicationMouseTracking {
            _ = session.sendMouse(
                action: 2,
                button: 1,
                modifiers: event.modifierFlags,
                x: point.x,
                y: point.y
            )
            return
        }
        selectionEnd = gridPoint(for: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard applicationMouseTracking else { return }
        let point = convert(event.locationInWindow, from: nil)
        _ = session.sendMouse(
            action: 1,
            button: 1,
            modifiers: event.modifierFlags,
            x: point.x,
            y: point.y
        )
        applicationMouseTracking = false
    }

    override func scrollWheel(with event: NSEvent) {
        let lines = Int(event.scrollingDeltaY.rounded(.awayFromZero))
        if lines != 0 { session.scroll(lines: lines) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let gridPoint = gridPointIfInside(for: point),
              snapshot.cells.indices.contains(gridPoint.row),
              snapshot.cells[gridPoint.row].indices.contains(gridPoint.column),
              snapshot.cells[gridPoint.row][gridPoint.column].hyperlink != nil else {
            contextMenuLinkPoint = nil
            return nil
        }
        contextMenuLinkPoint = gridPoint
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Open Link",
            action: #selector(openContextMenuLink),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func openContextMenuLink() {
        guard let contextMenuLinkPoint else { return }
        _ = session.openHyperlink(at: contextMenuLinkPoint)
    }

    private func gridPoint(for point: NSPoint) -> (column: Int, row: Int) {
        (
            max(0, min(snapshot.columns - 1, Int(point.x / cellWidth))),
            max(0, min(snapshot.rows - 1, Int(point.y / cellHeight)))
        )
    }

    private func gridPointIfInside(for point: NSPoint) -> (column: Int, row: Int)? {
        guard point.x >= 0, point.y >= 0,
              point.x < CGFloat(snapshot.columns) * cellWidth,
              point.y < CGFloat(snapshot.rows) * cellHeight else { return nil }
        return (Int(point.x / cellWidth), Int(point.y / cellHeight))
    }

    private func isSelected(column: Int, row: Int) -> Bool {
        guard let start = selectionStart, let end = selectionEnd else { return false }
        let first = start.row < end.row || (start.row == end.row && start.column <= end.column)
            ? start : end
        let last = first.row == start.row && first.column == start.column ? end : start
        if row < first.row || row > last.row { return false }
        if first.row == last.row { return column >= first.column && column <= last.column }
        if row == first.row { return column >= first.column }
        if row == last.row { return column <= last.column }
        return true
    }

    private func copySelection() {
        guard let selectionStart, let selectionEnd else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            session.text(from: selectionStart, to: selectionEnd),
            forType: .string
        )
    }

    private func pasteFromClipboard() {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        guard string.contains("\n") else { session.paste(string); return }
        let alert = NSAlert()
        alert.messageText = "Paste multiple lines?"
        alert.informativeText = "The pasted text may execute more than one command."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { session.paste(string) }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSMutableAttributedString()
        session.send(text: value)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = NSMutableAttributedString(
            attributedString: (string as? NSAttributedString)
                ?? NSAttributedString(string: (string as? String) ?? "")
        )
    }

    func unmarkText() { markedText = NSMutableAttributedString() }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
        markedText.length == 0
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.length)
    }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let rect = NSRect(
            x: CGFloat(snapshot.cursorColumn) * cellWidth,
            y: CGFloat(snapshot.cursorRow + 1) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        return window.convertToScreen(convert(rect, to: nil))
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {}
}
