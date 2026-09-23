import Foundation
import XCTest
@testable import DevHQ

final class TerminalLinkDetectorTests: XCTestCase {
    // MARK: - Pattern matching

    func testDetectsHTTPURLContainingClickedColumn() throws {
        let text = "Server ready at https://example.com/docs today"
        let match = try XCTUnwrap(detect(text, at: "https://example.com/docs"))
        XCTAssertEqual(match.kind, .url)
        XCTAssertEqual(match.target, "https://example.com/docs")
        XCTAssertNil(match.line)
        XCTAssertNil(match.column)
    }

    func testIgnoresCandidatesWhoseSpanExcludesClickedColumn() {
        let text = "see https://example.com now"
        XCTAssertNil(TerminalLinkDetector.detect(in: text, utf16Index: 0))
        XCTAssertNil(
            TerminalLinkDetector.detect(in: text, utf16Index: text.utf16.count - 1)
        )
    }

    func testSelectsTheCandidateWhoseSpanContainsTheClickedColumn() throws {
        let text = "https://first.example https://second.example"
        let first = try XCTUnwrap(detect(text, at: "https://first.example"))
        XCTAssertEqual(first.target, "https://first.example")
        let second = try XCTUnwrap(detect(text, at: "https://second.example"))
        XCTAssertEqual(second.target, "https://second.example")
    }

    func testTrimsTrailingPunctuationFromURL() throws {
        let text = "docs at https://example.com/a/b."
        let match = try XCTUnwrap(detect(text, at: "https://example.com/a/b"))
        XCTAssertEqual(match.target, "https://example.com/a/b")
    }

    func testTrimsUnbalancedClosingBracketsButKeepsBalancedOnes() {
        XCTAssertEqual(
            TerminalLinkDetector.trimmedTarget("https://example.com/a)"),
            "https://example.com/a"
        )
        XCTAssertEqual(
            TerminalLinkDetector.trimmedTarget("https://en.wikipedia.org/wiki/A_(b)"),
            "https://en.wikipedia.org/wiki/A_(b)"
        )
        XCTAssertEqual(
            TerminalLinkDetector.trimmedTarget("path/to/file]},"),
            "path/to/file"
        )
    }

    func testDetectsFileURL() throws {
        let text = "wrote file:///tmp/report%20final.html output"
        let match = try XCTUnwrap(detect(text, at: "file:///tmp/report%20final.html"))
        XCTAssertEqual(match.kind, .fileURL)
        XCTAssertEqual(match.target, "file:///tmp/report%20final.html")
    }

    func testDetectsPathWithLineAndColumn() throws {
        let text = "Sources/App/main.swift:42:7: error: something"
        let match = try XCTUnwrap(detect(text, at: "Sources/App/main.swift"))
        XCTAssertEqual(match.kind, .path)
        XCTAssertEqual(match.target, "Sources/App/main.swift")
        XCTAssertEqual(match.line, 42)
        XCTAssertEqual(match.column, 7)
    }

    func testDetectsPathWithLineOnly() throws {
        let text = "at src/util.py:12,"
        let match = try XCTUnwrap(detect(text, at: "src/util.py"))
        XCTAssertEqual(match.kind, .path)
        XCTAssertEqual(match.target, "src/util.py")
        XCTAssertEqual(match.line, 12)
        XCTAssertNil(match.column)
    }

    func testDetectsAbsoluteAndRelativePaths() throws {
        let absolute = try XCTUnwrap(detect("ls /usr/local/bin", at: "/usr/local/bin"))
        XCTAssertEqual(absolute.kind, .path)
        XCTAssertEqual(absolute.target, "/usr/local/bin")
        XCTAssertNil(absolute.line)

        let relative = try XCTUnwrap(detect("open docs/index.html now", at: "docs/index.html"))
        XCTAssertEqual(relative.kind, .path)
        XCTAssertEqual(relative.target, "docs/index.html")

        let bare = try XCTUnwrap(detect("compile main.swift now", at: "main.swift"))
        XCTAssertEqual(bare.kind, .path)
        XCTAssertEqual(bare.target, "main.swift")
    }

    func testURLKindKeepsPortLikeSuffixes() throws {
        let text = "listening on http://localhost:3000"
        let match = try XCTUnwrap(detect(text, at: "http://localhost:3000"))
        XCTAssertEqual(match.kind, .url)
        XCTAssertEqual(match.target, "http://localhost:3000")
        XCTAssertNil(match.line)
    }

    func testReturnsNilForPlainProse() {
        XCTAssertNil(TerminalLinkDetector.detect(in: "hello world", utf16Index: 2))
        XCTAssertNil(TerminalLinkDetector.detect(in: "", utf16Index: 0))
    }

    // MARK: - Row text extraction

    func testLineFromCellsMapsClickedColumnToCharacterOffset() throws {
        let cells = "cat a/b.txt".map { character in
            TerminalCell(text: String(character))
        }
        let line = try XCTUnwrap(
            TerminalLinkDetector.line(fromCells: cells, clickedColumn: 6)
        )
        XCTAssertEqual(line.text, "cat a/b.txt")
        XCTAssertEqual(line.utf16Index, 6)
        XCTAssertNil(TerminalLinkDetector.line(fromCells: cells, clickedColumn: 99))
    }

    // MARK: - File resolution

    func testResolveFileStripsFileURLScheme() {
        XCTAssertEqual(
            TerminalLinkDetector.resolveFilePath(
                "file:///tmp/a%20b.html",
                currentDirectory: "/cwd",
                workspaceRoot: "/root"
            ),
            "/tmp/a b.html"
        )
    }

    func testResolveFileKeepsAbsoluteAndExpandsTilde() {
        XCTAssertEqual(
            TerminalLinkDetector.resolveFilePath(
                "/etc/hosts",
                currentDirectory: "/cwd",
                workspaceRoot: "/root"
            ),
            "/etc/hosts"
        )
        XCTAssertEqual(
            TerminalLinkDetector.resolveFilePath(
                "~/notes.md",
                currentDirectory: "/cwd",
                workspaceRoot: "/root"
            ),
            NSString(string: "~/notes.md").expandingTildeInPath
        )
    }

    func testResolveFilePrefersCwdThenWorkspaceRoot() {
        XCTAssertEqual(
            TerminalLinkDetector.resolveFilePath(
                "a/b.txt",
                currentDirectory: "/cwd",
                workspaceRoot: "/root"
            ),
            "/cwd/a/b.txt"
        )
        XCTAssertEqual(
            TerminalLinkDetector.resolveFilePath(
                "a/b.txt",
                currentDirectory: nil,
                workspaceRoot: "/root"
            ),
            "/root/a/b.txt"
        )
        XCTAssertNil(
            TerminalLinkDetector.resolveFilePath(
                "a/b.txt",
                currentDirectory: nil,
                workspaceRoot: nil
            )
        )
        XCTAssertNil(
            TerminalLinkDetector.resolveFilePath(
                "",
                currentDirectory: "/cwd",
                workspaceRoot: "/root"
            )
        )
    }

    // MARK: - Routing

    func testExistingHTMLFileRoutesToEditorWhenEnabled() {
        let match = TerminalLinkMatch(kind: .path, target: "docs/index.html", raw: "docs/index.html")
        XCTAssertEqual(
            route(match, isFile: { $0 == "/cwd/docs/index.html" }),
            .editor(path: "/cwd/docs/index.html", line: nil, column: nil)
        )
    }

    func testExistingHTMLFileRoutesToEditorWhenDisabled() {
        var configuration = WebViewConfiguration()
        configuration.openHTMLFiles = false
        let match = TerminalLinkMatch(kind: .path, target: "docs/index.html", raw: "docs/index.html")
        XCTAssertEqual(
            route(match, configuration: configuration, isFile: { _ in true }),
            .editor(path: "/cwd/docs/index.html", line: nil, column: nil)
        )
    }

    func testRelativeFileFallsBackToWorkspaceWhenAbsentFromShellDirectory() {
        let match = TerminalLinkMatch(kind: .path, target: "main.swift", raw: "main.swift")
        XCTAssertEqual(
            route(match, isFile: { $0 == "/root/main.swift" }),
            .editor(path: "/root/main.swift", line: nil, column: nil)
        )
    }

    func testMissingFileIsUnhandled() {
        let match = TerminalLinkMatch(kind: .path, target: "docs/index.html", raw: "docs/index.html")
        XCTAssertEqual(route(match, isFile: { _ in false }), .unhandled)
    }

    func testExistingSourceFileRoutesToEditorWithLineAndColumn() {
        let match = TerminalLinkMatch(
            kind: .path,
            target: "src/main.swift",
            line: 10,
            column: 4,
            raw: "src/main.swift:10:4"
        )
        XCTAssertEqual(
            route(match, isFile: { _ in true }),
            .editor(path: "/cwd/src/main.swift", line: 10, column: 4)
        )
    }

    func testURLRoutingAlwaysPromptsForDestination() throws {
        let match = TerminalLinkMatch(
            kind: .url,
            target: "http://localhost:3000/app",
            raw: "http://localhost:3000/app"
        )
        XCTAssertEqual(route(match), .prompt(try XCTUnwrap(URL(string: "http://localhost:3000/app"))))

        let loopback = TerminalLinkMatch(
            kind: .url,
            target: "http://127.0.0.1:8080",
            raw: "http://127.0.0.1:8080"
        )
        XCTAssertEqual(route(loopback), .prompt(try XCTUnwrap(URL(string: "http://127.0.0.1:8080"))))
    }

    func testPublicURLRoutingAlwaysPrompts() throws {
        let match = TerminalLinkMatch(
            kind: .url,
            target: "https://example.com",
            raw: "https://example.com"
        )
        let url = try XCTUnwrap(URL(string: "https://example.com"))

        XCTAssertEqual(route(match), .prompt(url))

        var configuration = WebViewConfiguration()
        configuration.publicURLAction = .webview
        XCTAssertEqual(route(match, configuration: configuration), .prompt(url))
        configuration.publicURLAction = .system
        XCTAssertEqual(route(match, configuration: configuration), .prompt(url))
    }

    // MARK: - Helpers

    private func detect(_ text: String, at substring: String) -> TerminalLinkMatch? {
        guard let range = text.range(of: substring) else { return nil }
        let index = text.utf16.distance(
            from: text.utf16.startIndex,
            to: range.lowerBound.samePosition(in: text.utf16) ?? text.utf16.startIndex
        )
        return TerminalLinkDetector.detect(in: text, utf16Index: index)
    }

    private func route(
        _ match: TerminalLinkMatch,
        configuration: WebViewConfiguration = WebViewConfiguration(),
        isFile: (String) -> Bool = { _ in true }
    ) -> TerminalLinkRoute {
        TerminalLinkRouter.route(
            match,
            configuration: configuration,
            currentDirectory: "/cwd",
            workspaceRoot: "/root",
            isFile: isFile
        )
    }
}
