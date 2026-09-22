import Foundation
import XCTest
@testable import DevHQ

final class TerminalGraphemeTests: XCTestCase {
    @MainActor
    func testGhosttySnapshotPreservesClusteredZWJEmojiScalars() throws {
        guard TerminalSession.usesGhosttyRenderer else {
            throw XCTSkip("The production grapheme check requires the Ghostty VT bridge")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let emoji = "👩🏽‍🚀"
        let session = try TerminalSession(
            rootURL: root,
            command: ["/usr/bin/printf", "%s", "\u{1B}[?2027h" + emoji]
        )
        defer { session.close() }

        let deadline = Date().addingTimeInterval(3)
        while !snapshotText(session).contains(emoji), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        let cells = session.snapshot.cells.flatMap { $0 }
        let emojiIndex = try XCTUnwrap(
            cells.firstIndex { $0.text == emoji },
            "nonblank cell scalars: \(scalarDiagnostics(cells))"
        )
        XCTAssertEqual(cells[emojiIndex].text.unicodeScalars.map(\.value), emoji.unicodeScalars.map(\.value))
        XCTAssertEqual(cells[emojiIndex].width, 2)
        XCTAssertEqual(cells[emojiIndex + 1].width, 0)
    }

    @MainActor
    func testGhosttySnapshotPreservesZWJEmojiScalarsAcrossCells() throws {
        guard TerminalSession.usesGhosttyRenderer else {
            throw XCTSkip("The production grapheme check requires the Ghostty VT bridge")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let emoji = "👩🏽‍🚀"
        let session = try TerminalSession(rootURL: root, command: ["/usr/bin/printf", "%s", emoji])
        defer { session.close() }

        let deadline = Date().addingTimeInterval(3)
        while !snapshotText(session).contains(emoji), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        let cells = session.snapshot.cells.flatMap { $0 }
        // Ghostty represents this ZWJ sequence over multiple cells. The
        // bridge must preserve its ordered scalars rather than truncate a
        // cell-local buffer or manufacture a combined cell.
        XCTAssertEqual(
            cells.filter { $0.text != " " }.flatMap { $0.text.unicodeScalars.map(\.value) },
            emoji.unicodeScalars.map(\.value),
            "nonblank cell scalars: \(scalarDiagnostics(cells))"
        )
    }

    @MainActor
    func testGhosttySnapshotPreservesLongCombiningGraphemeAndWideEmoji() throws {
        guard TerminalSession.usesGhosttyRenderer else {
            throw XCTSkip("The production grapheme check requires the Ghostty VT bridge")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Nine scalars exercises the former eight-scalar bridge limit.
        let combining = "a" + String(repeating: "\u{0301}", count: 8)
        let emoji = "🙂"
        let session = try TerminalSession(
            rootURL: root,
            // Keep the independently-wide scalar ahead of the long combining
            // grapheme so each source cell has an unambiguous assertion.
            command: ["/usr/bin/printf", "%s", emoji + combining]
        )
        defer { session.close() }

        let deadline = Date().addingTimeInterval(3)
        while !snapshotText(session).contains(emoji), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        let cells = session.snapshot.cells.flatMap { $0 }
        let combinedCell = try XCTUnwrap(cells.first { $0.text == combining })
        XCTAssertEqual(combinedCell.text.unicodeScalars.map(\.value), combining.unicodeScalars.map(\.value))

        let emojiIndex = try XCTUnwrap(cells.firstIndex { $0.text == emoji })
        XCTAssertEqual(cells[emojiIndex].text.unicodeScalars.map(\.value), emoji.unicodeScalars.map(\.value))
        XCTAssertEqual(cells[emojiIndex].width, 2)
        XCTAssertEqual(cells[emojiIndex + 1].width, 0)
        XCTAssertEqual(cells[emojiIndex + 1].text, " ")

        // Empty Ghostty cells remain display blanks rather than invalid strings.
        XCTAssertTrue(cells.contains { $0.text == " " && $0.width == 1 })
    }
}

@MainActor
private func snapshotText(_ session: TerminalSession) -> String {
    session.snapshot.cells.flatMap { $0 }.map(\.text).joined()
}

private func scalarDiagnostics(_ cells: [TerminalCell]) -> String {
    cells.enumerated()
        .filter { $0.element.text != " " }
        .prefix(8)
        .map { "\($0.offset): \($0.element.text.unicodeScalars.map(\.value))" }
        .joined(separator: "; ")
}
