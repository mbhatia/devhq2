import AppKit
import Foundation
import TerminalBridge
@preconcurrency import UserNotifications

@MainActor
protocol TerminalHostServices: AnyObject {
    func open(url: URL)
    func showNotification(title: String, body: String)
    func writeClipboard(_ string: String)
}

@MainActor
final class SystemTerminalHostServices: TerminalHostServices {
    static let shared = SystemTerminalHostServices()
    private var lastNotificationDate = Date.distantPast

    private init() {}

    func open(url: URL) {
        NSWorkspace.shared.open(url)
    }

    func showNotification(title: String, body: String) {
        let now = Date()
        guard now.timeIntervalSince(lastNotificationDate) >= 1 else { return }
        lastNotificationDate = now
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app",
              Bundle.main.bundleIdentifier != nil else {
            NSApplication.shared.requestUserAttention(.informationalRequest)
            NSSound.beep()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }
    }

    func writeClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        if !string.isEmpty {
            NSPasteboard.general.setString(string, forType: .string)
        }
    }
}

struct TerminalRGB: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var nsColor: NSColor {
        NSColor(
            calibratedRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }
}

struct TerminalCell: Equatable, Sendable {
    var text = " "
    var foreground: TerminalRGB?
    var background: TerminalRGB?
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var inverse = false
    var width: UInt8 = 1
    var hyperlink: String?
}

enum TerminalCursorStyle: Equatable, Sendable {
    case block
    case bar
    case underline
}

struct TerminalRenderSnapshot: Equatable, Sendable {
    var columns: Int
    var rows: Int
    var cells: [[TerminalCell]]
    var cursorColumn: Int
    var cursorRow: Int
    var cursorVisible: Bool
    var cursorStyle: TerminalCursorStyle
    var scrollbackCount: Int
    var scrollOffset: Int

    static let empty = TerminalRenderSnapshot(
        columns: 80,
        rows: 24,
        cells: Array(repeating: Array(repeating: TerminalCell(), count: 80), count: 24),
        cursorColumn: 0,
        cursorRow: 0,
        cursorVisible: true,
        cursorStyle: .block,
        scrollbackCount: 0,
        scrollOffset: 0
    )
}

enum TerminalSessionError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        "Could not start the login shell."
    }
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    static var usesGhosttyRenderer: Bool { devhq_terminal_uses_ghostty() }

    let id = UUID()
    let rootURL: URL
    let processID: Int32
    @Published private(set) var title = "Terminal"
    @Published private(set) var currentDirectory: URL
    @Published private(set) var exitStatus: Int?
    @Published private(set) var snapshot = TerminalRenderSnapshot.empty
    /// Called once when the child process exits without the session being explicitly closed.
    var onNaturalExit: ((Int) -> Void)? {
        didSet { deliverNaturalExitIfNeeded() }
    }
    /// Called when the terminal emits BEL or an OSC notification.
    var onAttention: (() -> Void)?
    /// Called when this terminal gains keyboard focus.
    var onFocus: (() -> Void)?
    /// Called for text, key, or paste input originating in the terminal view.
    var onUserInput: (() -> Void)?
    private var nativeHandle: OpaquePointer?
    private var timer: Timer?
    private var parser = TerminalParser(columns: 80, rows: 24)
    private let hostServices: TerminalHostServices
    private var pendingNotification: (title: String, body: String)?
    private var lastNotificationDate = Date.distantPast
    private var active = true
    private var closed = false
    private var naturalExitDelivered = false

    init(
        rootURL: URL,
        workingDirectory: URL? = nil,
        command: [String]? = nil,
        shell: String? = nil,
        hostServices: TerminalHostServices? = nil
    ) throws {
        let workingDirectory = workingDirectory ?? rootURL
        let command = command?.isEmpty == false ? command : nil
        guard command?.contains(where: { $0.utf8.contains(0) }) != true else {
            throw TerminalSessionError.couldNotStart
        }
        self.rootURL = rootURL
        self.currentDirectory = workingDirectory
        self.hostServices = hostServices ?? SystemTerminalHostServices.shared
        let shell = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let terminfo = Bundle.module.resourceURL?
            .appendingPathComponent("Resources/terminfo", isDirectory: true).path
        let argumentPointers = command?.map { strdup($0) } ?? []
        defer { argumentPointers.forEach { free($0) } }
        guard !argumentPointers.contains(where: { $0 == nil }) else {
            throw TerminalSessionError.couldNotStart
        }
        nativeHandle = argumentPointers.withUnsafeBufferPointer { arguments in
            workingDirectory.path.withCString { cwd in
                shell.withCString { shell in
                    if let terminfo {
                        return terminfo.withCString {
                            devhq_terminal_create(
                                cwd, shell, $0, arguments.baseAddress, arguments.count,
                                80, 24, 0, 0
                            )
                        }
                    }
                    return devhq_terminal_create(
                        cwd, shell, nil, arguments.baseAddress, arguments.count,
                        80, 24, 0, 0
                    )
                }
            }
        }
        guard let nativeHandle else { throw TerminalSessionError.couldNotStart }
        processID = devhq_terminal_pid(nativeHandle)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    deinit {
        timer?.invalidate()
        if let nativeHandle { devhq_terminal_close(nativeHandle) }
    }

    var displayTitle: String {
        if let exitStatus { return "\(title) [exit \(exitStatus)]" }
        return title
    }

    var hasExited: Bool { exitStatus != nil }

    /// The currently visible terminal rows, independent of whether the session is active.
    var visibleText: String {
        Self.plainText(from: makeGhosttySnapshot() ?? parser.snapshot())
    }

    func setActive(_ isActive: Bool) {
        active = isActive
        if isActive { publishParserState() }
    }

    func send(text: String) {
        send(bytes: Array(text.utf8))
    }

    func sendUser(text: String) {
        guard !text.isEmpty else { return }
        onUserInput?()
        send(text: text)
    }

    func send(bytes: [UInt8]) {
        guard let nativeHandle, !bytes.isEmpty, exitStatus == nil else { return }
        bytes.withUnsafeBufferPointer {
            _ = devhq_terminal_write(nativeHandle, $0.baseAddress, $0.count)
        }
    }

    func sendUser(bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        onUserInput?()
        send(bytes: bytes)
    }

    func sendSpecialKey(_ key: TerminalSpecialKey, modifiers: NSEvent.ModifierFlags) {
        if let nativeHandle, devhq_terminal_uses_ghostty() {
            var nativeModifiers: UInt16 = 0
            if modifiers.contains(.shift) { nativeModifiers |= 1 << 0 }
            if modifiers.contains(.control) { nativeModifiers |= 1 << 1 }
            if modifiers.contains(.option) { nativeModifiers |= 1 << 2 }
            if modifiers.contains(.command) { nativeModifiers |= 1 << 3 }
            if modifiers.contains(.capsLock) { nativeModifiers |= 1 << 4 }
            if devhq_terminal_key(nativeHandle, key.rawValue, nativeModifiers) { return }
        }
        let control = modifiers.contains(.control)
        let option = modifiers.contains(.option)
        var bytes: [UInt8]
        switch key {
        case .up: bytes = Array("\u{1B}[A".utf8)
        case .down: bytes = Array("\u{1B}[B".utf8)
        case .right: bytes = Array("\u{1B}[C".utf8)
        case .left: bytes = Array("\u{1B}[D".utf8)
        case .home: bytes = Array("\u{1B}[H".utf8)
        case .end: bytes = Array("\u{1B}[F".utf8)
        case .pageUp: bytes = Array("\u{1B}[5~".utf8)
        case .pageDown: bytes = Array("\u{1B}[6~".utf8)
        case .delete: bytes = Array("\u{1B}[3~".utf8)
        case .backspace: bytes = [0x7f]
        case .tab: bytes = [0x09]
        case .returnKey: bytes = [0x0d]
        case .escape: bytes = [0x1b]
        }
        if control, key == .backspace { bytes = [0x08] }
        if option { bytes.insert(0x1b, at: 0) }
        send(bytes: bytes)
    }

    func sendUserSpecialKey(_ key: TerminalSpecialKey, modifiers: NSEvent.ModifierFlags) {
        onUserInput?()
        sendSpecialKey(key, modifiers: modifiers)
    }

    func paste(_ string: String) {
        if let nativeHandle, devhq_terminal_uses_ghostty() {
            let encoded = string.utf8CString
            if encoded.withUnsafeBufferPointer({
                devhq_terminal_paste(nativeHandle, $0.baseAddress, max(0, $0.count - 1))
            }) { return }
        }
        var text = string
            .replacingOccurrences(of: "\u{0}", with: " ")
            .replacingOccurrences(of: "\u{1b}", with: " ")
        if parser.bracketedPaste {
            text = "\u{1B}[200~" + text + "\u{1B}[201~"
        } else {
            text = text.replacingOccurrences(of: "\n", with: "\r")
        }
        send(text: text)
    }

    func pasteFromUser(_ string: String) {
        guard !string.isEmpty else { return }
        onUserInput?()
        paste(string)
    }

    func setFocused(_ focused: Bool) {
        if focused { onFocus?() }
        if let nativeHandle, devhq_terminal_uses_ghostty(),
           devhq_terminal_focus(nativeHandle, focused) { return }
        guard parser.focusReporting else { return }
        send(text: focused ? "\u{1B}[I" : "\u{1B}[O")
    }

    func sendMouse(
        action: Int32,
        button: Int32,
        modifiers: NSEvent.ModifierFlags,
        x: CGFloat,
        y: CGFloat
    ) -> Bool {
        guard let nativeHandle, devhq_terminal_uses_ghostty() else { return false }
        var nativeModifiers: UInt16 = 0
        if modifiers.contains(.shift) { nativeModifiers |= 1 << 0 }
        if modifiers.contains(.control) { nativeModifiers |= 1 << 1 }
        if modifiers.contains(.option) { nativeModifiers |= 1 << 2 }
        if modifiers.contains(.command) { nativeModifiers |= 1 << 3 }
        return devhq_terminal_mouse(
            nativeHandle,
            action,
            button,
            nativeModifiers,
            Float(x),
            Float(y)
        )
    }

    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        guard let nativeHandle else { return }
        let columns = max(1, min(columns, Int(UInt16.max)))
        let rows = max(1, min(rows, Int(UInt16.max)))
        parser.resize(columns: columns, rows: rows)
        _ = devhq_terminal_resize(
            nativeHandle,
            UInt16(columns),
            UInt16(rows),
            UInt32(clamping: pixelWidth),
            UInt32(clamping: pixelHeight)
        )
        if active { publishParserState() }
    }

    func scroll(lines: Int) {
        parser.scrollViewport(lines: lines)
        if active { publishParserState() }
    }

    func text(from start: (column: Int, row: Int), to end: (column: Int, row: Int)) -> String {
        parser.text(from: start, to: end)
    }

    func openHyperlink(at point: (column: Int, row: Int)) -> Bool {
        guard let url = hyperlink(at: point) else { return false }
        hostServices.open(url: url)
        return true
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.invalidate()
        timer = nil
        if let nativeHandle {
            devhq_terminal_close(nativeHandle)
            self.nativeHandle = nil
        }
    }

    private func drain() {
        guard let nativeHandle else { return }
        var changed = false
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer {
                devhq_terminal_read(nativeHandle, $0.baseAddress, $0.count)
            }
            guard count > 0 else { break }
            parser.feed(buffer.prefix(Int(count)))
            changed = true
        }
        for effect in parser.takeEffects() {
            switch effect {
            case .bell:
                onAttention?()
            case let .notification(title, body):
                onAttention?()
                pendingNotification = (title, body)
            case let .clipboardWrite(string):
                hostServices.writeClipboard(string)
            }
        }
        deliverPendingNotification()
        if exitStatus == nil {
            var status: Int32 = 0
            if devhq_terminal_poll_exit(nativeHandle, &status) {
                exitStatus = Int(status)
                changed = true
                deliverNaturalExitIfNeeded()
            }
        }
        if title != parser.title { title = parser.title }
        if let cwd = parser.currentDirectory, cwd != currentDirectory { currentDirectory = cwd }
        if changed, active { publishParserState() }
    }

    private func deliverPendingNotification() {
        guard let pendingNotification else { return }
        let now = Date()
        guard now.timeIntervalSince(lastNotificationDate) >= 1 else { return }
        self.pendingNotification = nil
        lastNotificationDate = now
        hostServices.showNotification(
            title: pendingNotification.title,
            body: pendingNotification.body
        )
    }

    private func publishParserState() {
        if let ghosttySnapshot = makeGhosttySnapshot() {
            snapshot = ghosttySnapshot
        } else {
            snapshot = parser.snapshot()
        }
    }

    private func deliverNaturalExitIfNeeded() {
        guard !closed, !naturalExitDelivered, let exitStatus, let onNaturalExit else { return }
        naturalExitDelivered = true
        onNaturalExit(exitStatus)
    }

    private static func plainText(from snapshot: TerminalRenderSnapshot) -> String {
        snapshot.cells.map { row in
            row.map(\.text).joined()
                .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    private func hyperlink(at point: (column: Int, row: Int)) -> URL? {
        guard point.column >= 0, point.row >= 0 else { return nil }
        var value: String?
        if let nativeHandle, devhq_terminal_uses_ghostty(),
           point.column <= Int(UInt16.max), point.row <= Int(UInt16.max) {
            let required = devhq_terminal_hyperlink_at(
                nativeHandle,
                UInt16(point.column),
                UInt16(point.row),
                nil,
                0
            )
            if required > 0, required <= 64 * 1024 {
                var bytes = [UInt8](repeating: 0, count: required)
                let copied = bytes.withUnsafeMutableBufferPointer {
                    devhq_terminal_hyperlink_at(
                        nativeHandle,
                        UInt16(point.column),
                        UInt16(point.row),
                        $0.baseAddress,
                        $0.count
                    )
                }
                if copied == required { value = String(bytes: bytes, encoding: .utf8) }
            }
        } else {
            let fallback = parser.snapshot()
            if fallback.cells.indices.contains(point.row),
               fallback.cells[point.row].indices.contains(point.column) {
                value = fallback.cells[point.row][point.column].hyperlink
            }
        }
        guard let value, let url = URL(string: value), url.scheme != nil else { return nil }
        return url
    }

    private func makeGhosttySnapshot() -> TerminalRenderSnapshot? {
        guard devhq_terminal_uses_ghostty(), let nativeHandle else { return nil }
        let fallback = parser.snapshot()
        var nativeSnapshot = DevHQTerminalSnapshot()
        var nativeCells = [DevHQTerminalCell](
            repeating: DevHQTerminalCell(),
            count: fallback.columns * fallback.rows
        )
        let success = nativeCells.withUnsafeMutableBufferPointer {
            devhq_terminal_snapshot(nativeHandle, $0.baseAddress, $0.count, &nativeSnapshot)
        }
        guard success,
              nativeSnapshot.columns > 0,
              nativeSnapshot.rows > 0 else { return nil }
        let columns = Int(nativeSnapshot.columns)
        let rows = Int(nativeSnapshot.rows)
        guard nativeCells.count >= columns * rows else { return nil }
        let cells = (0..<rows).map { row in
            (0..<columns).map { column in
                Self.cell(from: nativeCells[row * columns + column])
            }
        }
        let cursorStyle: TerminalCursorStyle = switch nativeSnapshot.cursor_style {
        case 1: .bar
        case 2: .underline
        default: .block
        }
        return TerminalRenderSnapshot(
            columns: columns,
            rows: rows,
            cells: cells,
            cursorColumn: Int(nativeSnapshot.cursor_column),
            cursorRow: Int(nativeSnapshot.cursor_row),
            cursorVisible: nativeSnapshot.cursor_visible != 0,
            cursorStyle: cursorStyle,
            scrollbackCount: fallback.scrollbackCount,
            scrollOffset: fallback.scrollOffset
        )
    }

    private static func cell(from native: DevHQTerminalCell) -> TerminalCell {
        let codepoints = [
            native.codepoint0, native.codepoint1, native.codepoint2, native.codepoint3,
            native.codepoint4, native.codepoint5, native.codepoint6, native.codepoint7
        ]
        let scalars = codepoints.prefix(Int(native.codepoint_count)).compactMap(UnicodeScalar.init)
        let text = scalars.isEmpty ? " " : String(String.UnicodeScalarView(scalars))
        return TerminalCell(
            text: text,
            foreground: native.has_foreground == 0 ? nil : TerminalRGB(
                red: native.foreground_red,
                green: native.foreground_green,
                blue: native.foreground_blue
            ),
            background: native.has_background == 0 ? nil : TerminalRGB(
                red: native.background_red,
                green: native.background_green,
                blue: native.background_blue
            ),
            bold: native.flags & UInt8(DEVHQ_TERMINAL_CELL_BOLD) != 0,
            italic: native.flags & UInt8(DEVHQ_TERMINAL_CELL_ITALIC) != 0,
            underline: native.flags & UInt8(DEVHQ_TERMINAL_CELL_UNDERLINE) != 0,
            strikethrough: native.flags & UInt8(DEVHQ_TERMINAL_CELL_STRIKETHROUGH) != 0,
            inverse: native.flags & UInt8(DEVHQ_TERMINAL_CELL_INVERSE) != 0,
            width: native.width,
            hyperlink: native.flags & UInt8(DEVHQ_TERMINAL_CELL_HYPERLINK) != 0 ? "" : nil
        )
    }
}

enum TerminalSpecialKey: Int32 {
    case up, down, left, right, home, end, pageUp, pageDown, delete
    case backspace, tab, returnKey, escape
}

enum TerminalEffect: Equatable {
    case bell
    case notification(title: String, body: String)
    case clipboardWrite(String)
}

struct TerminalParser {
    private static let maxOSCBytes = 1024 * 1024
    private enum State { case ground, escape, csi, osc, oscEscape }
    private var state = State.ground
    private var sequence: [UInt8] = []
    private var printable: [UInt8] = []
    private var groundUTF8ContinuationCount = 0
    private var oscUTF8ContinuationCount = 0
    private var oscOverflowed = false
    private var pendingEffects: [TerminalEffect] = []
    private var cells: [[TerminalCell]]
    private var history: [[TerminalCell]] = []
    private var alternateCells: [[TerminalCell]]?
    private var savedCursor = (column: 0, row: 0)
    private(set) var columns: Int
    private(set) var rows: Int
    private var column = 0
    private var row = 0
    private var style = TerminalCell()
    private var currentHyperlink: String?
    private var cursorVisible = true
    private var cursorStyle = TerminalCursorStyle.block
    private var scrollOffset = 0
    private(set) var title = "Terminal"
    private(set) var currentDirectory: URL?
    private(set) var bracketedPaste = false
    private(set) var focusReporting = false

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        cells = Self.blankGrid(columns: columns, rows: rows)
    }

    mutating func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for byte in bytes {
            switch state {
            case .ground:
                if groundUTF8ContinuationCount > 0 {
                    printable.append(byte)
                    groundUTF8ContinuationCount -= 1
                    continue
                }
                switch byte {
                case 0x07: flushPrintable(); enqueue(.bell)
                case 0x1b: flushPrintable(); state = .escape
                case 0x9d: flushPrintable(); startOSC()
                case 0x0d: flushPrintable(); column = 0
                case 0x0a, 0x0b, 0x0c: flushPrintable(); lineFeed()
                case 0x08: flushPrintable(); column = max(0, column - 1)
                case 0x09: flushPrintable(); column = min(columns - 1, ((column / 8) + 1) * 8)
                case 0x20...0xff:
                    printable.append(byte)
                    groundUTF8ContinuationCount = Self.utf8ContinuationCount(after: byte)
                default: flushPrintable()
                }
            case .escape:
                if byte == 0x5b { sequence.removeAll(keepingCapacity: true); state = .csi }
                else if byte == 0x5d {
                    startOSC()
                }
                else if byte == 0x37 { savedCursor = (column, row); state = .ground }
                else if byte == 0x38 { (column, row) = savedCursor; state = .ground }
                else if byte == 0x44 { lineFeed(); state = .ground }
                else if byte == 0x4d { reverseIndex(); state = .ground }
                else if byte == 0x63 { reset(); state = .ground }
                else { state = .ground }
            case .csi:
                if (0x40...0x7e).contains(byte) {
                    handleCSI(final: byte)
                    sequence.removeAll(keepingCapacity: true)
                    state = .ground
                } else { sequence.append(byte) }
            case .osc:
                if oscUTF8ContinuationCount > 0 {
                    appendOSC(byte)
                    oscUTF8ContinuationCount -= 1
                }
                else if byte == 0x07 || byte == 0x9c { finishOSC(); state = .ground }
                else if byte == 0x1b { state = .oscEscape }
                else {
                    appendOSC(byte)
                    oscUTF8ContinuationCount = Self.utf8ContinuationCount(after: byte)
                }
            case .oscEscape:
                if byte == 0x5c { finishOSC(); state = .ground }
                else {
                    appendOSC(0x1b)
                    appendOSC(byte)
                    oscUTF8ContinuationCount = Self.utf8ContinuationCount(after: byte)
                    state = .osc
                }
            }
        }
        flushPrintable()
    }

    mutating func takeEffects() -> [TerminalEffect] {
        defer { pendingEffects.removeAll(keepingCapacity: true) }
        return pendingEffects
    }

    mutating func resize(columns newColumns: Int, rows newRows: Int) {
        guard newColumns != columns || newRows != rows else { return }
        var resized = Self.blankGrid(columns: newColumns, rows: newRows)
        for y in 0..<min(rows, newRows) {
            for x in 0..<min(columns, newColumns) { resized[y][x] = cells[y][x] }
        }
        columns = newColumns
        rows = newRows
        cells = resized
        column = min(column, columns - 1)
        row = min(row, rows - 1)
    }

    mutating func scrollViewport(lines: Int) {
        scrollOffset = max(0, min(history.count, scrollOffset + lines))
    }

    func snapshot() -> TerminalRenderSnapshot {
        let allRows = history + cells
        let end = max(rows, allRows.count - scrollOffset)
        let start = max(0, end - rows)
        var visible = Array(allRows[start..<min(end, allRows.count)])
        while visible.count < rows {
            visible.insert(Array(repeating: TerminalCell(), count: columns), at: 0)
        }
        return TerminalRenderSnapshot(
            columns: columns,
            rows: rows,
            cells: visible,
            cursorColumn: column,
            cursorRow: row,
            cursorVisible: cursorVisible && scrollOffset == 0,
            cursorStyle: cursorStyle,
            scrollbackCount: history.count,
            scrollOffset: scrollOffset
        )
    }

    func text(from start: (column: Int, row: Int), to end: (column: Int, row: Int)) -> String {
        let snapshot = snapshot()
        let first = min(start.row, end.row)
        let last = max(start.row, end.row)
        return (first...last).compactMap { y -> String? in
            guard snapshot.cells.indices.contains(y) else { return nil }
            let lower = y == first ? (start.row <= end.row ? start.column : end.column) : 0
            let upper = y == last ? (start.row <= end.row ? end.column : start.column) : columns - 1
            guard lower <= upper else { return "" }
            return snapshot.cells[y][max(0, lower)...min(columns - 1, upper)]
                .map(\.text).joined().replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    private static func blankGrid(columns: Int, rows: Int) -> [[TerminalCell]] {
        Array(repeating: Array(repeating: TerminalCell(), count: columns), count: rows)
    }

    private mutating func flushPrintable() {
        guard !printable.isEmpty, let string = String(bytes: printable, encoding: .utf8) else { return }
        printable.removeAll(keepingCapacity: true)
        for character in string { put(character) }
    }

    private mutating func put(_ character: Character) {
        if column >= columns { column = 0; lineFeed() }
        var cell = style
        cell.text = String(character)
        cell.width = character.unicodeScalars.contains { $0.properties.isEmojiPresentation } ? 2 : 1
        cell.hyperlink = currentHyperlink
        cells[row][column] = cell
        if cell.width == 2, column + 1 < columns {
            var spacer = style
            spacer.text = ""
            spacer.width = 0
            spacer.hyperlink = currentHyperlink
            cells[row][column + 1] = spacer
        }
        column += Int(cell.width)
    }

    private mutating func lineFeed() {
        if row == rows - 1 {
            if alternateCells == nil {
                history.append(cells.removeFirst())
                if history.count > 10_000 { history.removeFirst(history.count - 10_000) }
            } else { cells.removeFirst() }
            cells.append(Array(repeating: TerminalCell(), count: columns))
        } else { row += 1 }
        scrollOffset = 0
    }

    private mutating func reverseIndex() {
        if row == 0 {
            cells.insert(Array(repeating: TerminalCell(), count: columns), at: 0)
            cells.removeLast()
        } else { row -= 1 }
    }

    private mutating func reset() {
        cells = Self.blankGrid(columns: columns, rows: rows)
        history.removeAll()
        column = 0
        row = 0
        style = TerminalCell()
        currentHyperlink = nil
        cursorVisible = true
        cursorStyle = .block
    }

    private mutating func handleCSI(final: UInt8) {
        let raw = String(decoding: sequence, as: UTF8.self)
        let privateMode = raw.hasPrefix("?")
        let body = privateMode ? String(raw.dropFirst()) : raw
        let params = body.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let first = max(1, params.first ?? 1)
        switch UnicodeScalar(final) {
        case "A": row = max(0, row - first)
        case "B": row = min(rows - 1, row + first)
        case "C": column = min(columns - 1, column + first)
        case "D": column = max(0, column - first)
        case "G": column = min(columns - 1, first - 1)
        case "H", "f":
            row = min(rows - 1, max(0, (params.first ?? 1) - 1))
            column = min(columns - 1, max(0, (params.dropFirst().first ?? 1) - 1))
        case "J":
            if params.first == 2 || params.first == 3 { cells = Self.blankGrid(columns: columns, rows: rows) }
            else {
                for x in column..<columns { cells[row][x] = TerminalCell() }
                if row + 1 < rows { for y in (row + 1)..<rows { cells[y] = Array(repeating: TerminalCell(), count: columns) } }
            }
        case "K":
            let mode = params.first ?? 0
            let range = mode == 1 ? 0...column : (mode == 2 ? 0...(columns - 1) : column...(columns - 1))
            for x in range { cells[row][x] = TerminalCell() }
        case "m": applySGR(params.isEmpty ? [0] : params)
        case "h" where privateMode, "l" where privateMode:
            let enabled = final == 0x68
            for mode in params {
                switch mode {
                case 25: cursorVisible = enabled
                case 1004: focusReporting = enabled
                case 2004: bracketedPaste = enabled
                case 1049: setAlternateScreen(enabled)
                default: break
                }
            }
        case "q":
            switch params.first ?? 0 {
            case 3, 4: cursorStyle = .underline
            case 5, 6: cursorStyle = .bar
            default: cursorStyle = .block
            }
        default: break
        }
    }

    private mutating func applySGR(_ params: [Int]) {
        var index = 0
        while index < params.count {
            let value = params[index]
            switch value {
            case 0: style = TerminalCell()
            case 1: style.bold = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 9: style.strikethrough = true
            case 22: style.bold = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 29: style.strikethrough = false
            case 30...37: style.foreground = Self.palette(value - 30)
            case 40...47: style.background = Self.palette(value - 40)
            case 90...97: style.foreground = Self.palette(value - 90 + 8)
            case 100...107: style.background = Self.palette(value - 100 + 8)
            case 39: style.foreground = nil
            case 49: style.background = nil
            case 38, 48:
                if params.indices.contains(index + 4), params[index + 1] == 2 {
                    let color = TerminalRGB(
                        red: UInt8(clamping: params[index + 2]),
                        green: UInt8(clamping: params[index + 3]),
                        blue: UInt8(clamping: params[index + 4])
                    )
                    if value == 38 { style.foreground = color } else { style.background = color }
                    index += 4
                } else if params.indices.contains(index + 2), params[index + 1] == 5 {
                    let color = Self.palette256(params[index + 2])
                    if value == 38 { style.foreground = color } else { style.background = color }
                    index += 2
                }
            default: break
            }
            index += 1
        }
    }

    private mutating func handleOSC() {
        let value = String(decoding: sequence, as: UTF8.self)
        sequence.removeAll(keepingCapacity: true)
        guard let separator = value.firstIndex(of: ";") else { return }
        let command = value[..<separator]
        let content = String(value[value.index(after: separator)...])
        if command == "0" || command == "2" { title = content.isEmpty ? "Terminal" : content }
        if command == "7", let url = URL(string: content), url.isFileURL { currentDirectory = url }
        if command == "8" {
            let fields = content.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return }
            currentHyperlink = fields[1].isEmpty ? nil : String(fields[1])
        }
        if command == "9", !content.isEmpty {
            enqueue(.notification(
                title: title == "Terminal" ? "DevHQ Terminal" : title,
                body: content
            ))
        }
        if command == "52" {
            let fields = content.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[1] != "?",
                  let data = Data(base64Encoded: String(fields[1]), options: []),
                  let string = String(data: data, encoding: .utf8) else { return }
            enqueue(.clipboardWrite(string))
        }
    }

    private mutating func enqueue(_ effect: TerminalEffect) {
        let matchingIndex = pendingEffects.firstIndex {
            switch ($0, effect) {
            case (.bell, .bell), (.notification, .notification),
                 (.clipboardWrite, .clipboardWrite): true
            default: false
            }
        }
        if let matchingIndex { pendingEffects[matchingIndex] = effect }
        else { pendingEffects.append(effect) }
    }

    private mutating func startOSC() {
        sequence.removeAll(keepingCapacity: true)
        oscOverflowed = false
        oscUTF8ContinuationCount = 0
        state = .osc
    }

    private mutating func appendOSC(_ byte: UInt8) {
        if sequence.count < Self.maxOSCBytes { sequence.append(byte) }
        else { oscOverflowed = true }
    }

    private mutating func finishOSC() {
        if oscOverflowed { sequence.removeAll(keepingCapacity: true) }
        else { handleOSC() }
        oscOverflowed = false
        oscUTF8ContinuationCount = 0
    }

    private static func utf8ContinuationCount(after byte: UInt8) -> Int {
        switch byte {
        case 0xc2...0xdf: 1
        case 0xe0...0xef: 2
        case 0xf0...0xf4: 3
        default: 0
        }
    }

    private mutating func setAlternateScreen(_ enabled: Bool) {
        if enabled, alternateCells == nil {
            alternateCells = cells
            savedCursor = (column, row)
            cells = Self.blankGrid(columns: columns, rows: rows)
            column = 0; row = 0
        } else if !enabled, let primary = alternateCells {
            cells = primary
            alternateCells = nil
            (column, row) = savedCursor
        }
    }

    private static func palette(_ index: Int) -> TerminalRGB {
        let values: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
            (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
            (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
            (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255)
        ]
        let value = values[max(0, min(index, values.count - 1))]
        return TerminalRGB(red: value.0, green: value.1, blue: value.2)
    }

    private static func palette256(_ index: Int) -> TerminalRGB {
        if index < 16 { return palette(index) }
        if index >= 232 {
            let value = UInt8(clamping: 8 + (index - 232) * 10)
            return TerminalRGB(red: value, green: value, blue: value)
        }
        let value = index - 16
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        return TerminalRGB(
            red: levels[(value / 36) % 6],
            green: levels[(value / 6) % 6],
            blue: levels[value % 6]
        )
    }
}
