import Foundation
import XCTest
@testable import DevHQ

final class WebViewCommandsTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated {
            TerminalSession.detectedLinkHandler = nil
        }
        super.tearDown()
    }

    // MARK: - Target normalization

    func testFullURLsPassThrough() {
        XCTAssertEqual(
            WebTargetNormalizer.url(forTarget: "https://example.com/a", homeURL: "about:blank"),
            "https://example.com/a"
        )
        XCTAssertEqual(
            WebTargetNormalizer.url(forTarget: "about:blank", homeURL: "https://home"),
            "about:blank"
        )
        XCTAssertEqual(
            WebTargetNormalizer.url(forTarget: "vscode-insiders://open", homeURL: "about:blank"),
            "vscode-insiders://open"
        )
    }

    func testEmptyTargetFallsBackToHomeURL() {
        XCTAssertEqual(
            WebTargetNormalizer.url(forTarget: "", homeURL: "https://start.example"),
            "https://start.example"
        )
    }

    func testPathsBecomePercentEncodedFileURLs() {
        XCTAssertEqual(
            WebTargetNormalizer.url(forTarget: "/tmp/My Page.html", homeURL: "about:blank"),
            "file:///tmp/My%20Page.html"
        )
        XCTAssertEqual(
            WebTargetNormalizer.url(
                forTarget: "docs/a.html",
                homeURL: "about:blank",
                baseDirectory: "/base"
            ),
            "file:///base/docs/a.html"
        )
        let home = NSString(string: "~").expandingTildeInPath
        XCTAssertEqual(
            WebTargetNormalizer.url(forTarget: "~/page.html", homeURL: "about:blank"),
            "file://" + WebTargetNormalizer.percentEncodedPath(home + "/page.html")
        )
    }

    func testTitleFallsBackToLastURLPathSegment() {
        XCTAssertEqual(
            WebTargetNormalizer.title(forURL: "file:///tmp/My%20Page.html"),
            "My Page.html"
        )
        XCTAssertEqual(WebTargetNormalizer.title(forURL: "about:blank"), "Web Preview")
        XCTAssertEqual(WebTargetNormalizer.title(forURL: ""), "Web Preview")
        XCTAssertEqual(
            WebTargetNormalizer.title(forURL: "https://example.com"),
            "example.com"
        )
    }

    // MARK: - Web tab model

    @MainActor
    func testAddSelectAndCloseWebTabs() throws {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let root = try temporaryDirectory()
        workspace.openWorkspace(root)

        let first = WebViewTab(target: "https://one.example", homeURL: "about:blank")
        let second = WebViewTab(target: "https://two.example", homeURL: "about:blank")
        workspace.addWebTab(first)
        workspace.addWebTab(second)

        XCTAssertEqual(workspace.tabs.compactMap(\.web).count, 2)
        XCTAssertEqual(workspace.selectedTabID, second.id)
        XCTAssertEqual(workspace.selectedWebTab?.id, second.id)
        XCTAssertNil(workspace.selectedDocumentID)

        workspace.select(first)
        XCTAssertEqual(workspace.selectedWebTab?.id, first.id)

        workspace.close(first)
        XCTAssertEqual(workspace.tabs.compactMap(\.web).map(\.id), [second.id])
        XCTAssertEqual(workspace.selectedWebTab?.id, second.id)
    }

    @MainActor
    func testSharedWebTargetReusesOneTabPerWorktree() throws {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let root = try temporaryDirectory()
        workspace.openWorkspace(root)
        let configuration = WebViewConfiguration()

        let tab = openSharedWebTarget(
            "https://one.example",
            in: workspace,
            configuration: configuration
        )
        XCTAssertTrue(tab.isShared)
        XCTAssertEqual(tab.urlString, "https://one.example")
        XCTAssertEqual(workspace.selectedWebTab?.id, tab.id)

        let reused = openSharedWebTarget(
            "https://two.example",
            in: workspace,
            configuration: configuration
        )
        XCTAssertEqual(reused.id, tab.id)
        XCTAssertEqual(tab.urlString, "https://two.example")
        XCTAssertEqual(workspace.tabs.compactMap(\.web).count, 1)

        // A plain web tab does not become the shared one.
        let plain = openWebTab("https://three.example", in: workspace, configuration: configuration)
        XCTAssertFalse(plain.isShared)
        XCTAssertEqual(workspace.sharedWebTab?.id, tab.id)
    }

    @MainActor
    func testWebTabsParkAndRestoreAcrossWorktreeSwitches() throws {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let rootA = try temporaryDirectory()
        let rootB = try temporaryDirectory()
        workspace.openWorkspace(rootA)

        let tab = openSharedWebTarget(
            "https://parked.example",
            in: workspace,
            configuration: WebViewConfiguration()
        )

        workspace.openWorkspace(rootB)
        XCTAssertNil(workspace.sharedWebTab)
        XCTAssertTrue(workspace.tabs.isEmpty)

        workspace.openWorkspace(rootA)
        XCTAssertEqual(workspace.sharedWebTab?.id, tab.id)
        XCTAssertEqual(workspace.selectedWebTab?.id, tab.id)
        XCTAssertEqual(workspace.sharedWebTab?.urlString, "https://parked.example")
    }

    // MARK: - Command registration

    @MainActor
    func testRegistrationDefinesExpectedIdentifiersScopesAndAvailability() throws {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let settings = EditorSettings()
        let manager = CommandManager()
        try registerWebViewCommands(
            in: manager,
            workspace: workspace,
            settings: settings,
            prompts: prompts()
        )

        XCTAssertEqual(Set(manager.commandsByID.keys), [
            "web:open-url", "web:open-localhost", "web:open-active-file",
            "devhq:open-webview", "web:set-location", "web:reload", "web:back",
            "web:forward", "web:copy-url", "web:close"
        ])
        for id in ["web:open-url", "web:open-localhost", "web:open-active-file", "devhq:open-webview"] {
            XCTAssertEqual(
                manager.commandsByID[id]?.viewKinds,
                Set(CommandViewKind.allCases),
                id
            )
        }
        for id in ["web:set-location", "web:reload", "web:back", "web:forward", "web:copy-url", "web:close"] {
            XCTAssertEqual(manager.commandsByID[id]?.viewKinds, [.web], id)
        }

        // Without a workspace nothing is available.
        XCTAssertTrue(try manager.commands(in: CommandContext(view: .web)).isEmpty)

        let root = try temporaryDirectory()
        workspace.openWorkspace(root)
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .document)).map(\.id),
            ["devhq:open-webview", "web:open-active-file", "web:open-localhost", "web:open-url"]
        )
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .web)).map(\.id),
            ["devhq:open-webview", "web:open-active-file", "web:open-localhost", "web:open-url"]
        )

        workspace.addWebTab(WebViewTab(target: "https://example.com", homeURL: "about:blank"))
        XCTAssertEqual(
            try manager.commands(in: CommandContext(view: .web)).map(\.id),
            [
                "devhq:open-webview", "web:back", "web:close", "web:copy-url",
                "web:forward", "web:open-active-file", "web:open-localhost",
                "web:open-url", "web:reload", "web:set-location"
            ]
        )
    }

    @MainActor
    func testOpenWebviewCommandNavigatesSharedTabAndSetLocationNavigatesSelected() throws {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let settings = EditorSettings()
        let manager = CommandManager()
        let root = try temporaryDirectory()
        workspace.openWorkspace(root)
        var promptInput: String? = "https://shared.example"
        try registerWebViewCommands(
            in: manager,
            workspace: workspace,
            settings: settings,
            prompts: prompts(target: { _, _, _ in promptInput })
        )

        try manager.execute(id: "devhq:open-webview", in: CommandContext(view: .document))
        let shared = try XCTUnwrap(workspace.sharedWebTab)
        XCTAssertEqual(shared.urlString, "https://shared.example")
        XCTAssertEqual(workspace.selectedWebTab?.id, shared.id)

        promptInput = "https://moved.example"
        try manager.execute(id: "web:set-location", in: CommandContext(view: .web))
        XCTAssertEqual(shared.urlString, "https://moved.example")

        promptInput = nil
        try manager.execute(id: "devhq:open-webview", in: CommandContext(view: .document))
        XCTAssertEqual(workspace.tabs.compactMap(\.web).count, 1, "A cancelled prompt opens nothing")

        try manager.execute(id: "web:close", in: CommandContext(view: .web))
        XCTAssertNil(workspace.sharedWebTab)
        XCTAssertThrowsError(
            try manager.execute(id: "web:close", in: CommandContext(view: .web))
        )
    }

    @MainActor
    func testOpenActiveFileCommandUsesSelectedDocument() throws {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let settings = EditorSettings()
        let manager = CommandManager()
        let root = try temporaryDirectory()
        workspace.openWorkspace(root)
        let page = root.appendingPathComponent("page.html")
        try "<h1>hi</h1>".write(to: page, atomically: true, encoding: .utf8)
        workspace.openFile(page)
        try registerWebViewCommands(
            in: manager,
            workspace: workspace,
            settings: settings,
            prompts: prompts()
        )

        try manager.execute(id: "web:open-active-file", in: CommandContext(view: .document))
        let tab = try XCTUnwrap(workspace.selectedWebTab)
        XCTAssertEqual(tab.urlString, "file://" + WebTargetNormalizer.percentEncodedPath(page.path))
        XCTAssertFalse(tab.isShared)
    }

    // MARK: - Terminal link routing

    @MainActor
    func testInstalledHandlerRoutesFileTargetsIntoEditorWithCaret() throws {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let settings = EditorSettings()
        let root = try temporaryDirectory()
        workspace.openWorkspace(root)
        let file = root.appendingPathComponent("main.swift")
        try "let x = 1\nlet y = 2\n".write(to: file, atomically: true, encoding: .utf8)
        installTerminalLinkRouting(
            workspace: workspace,
            settings: settings,
            prompts: prompts(),
            openSystemURL: { _ in XCTFail("File targets must not open a browser") }
        )
        let handler = try XCTUnwrap(TerminalSession.detectedLinkHandler)

        let match = TerminalLinkMatch(
            kind: .path,
            target: "main.swift",
            line: 2,
            column: 5,
            raw: "main.swift:2:5"
        )
        XCTAssertTrue(handler(match, root, root))
        let document = try XCTUnwrap(workspace.selectedDocument)
        XCTAssertEqual(document.url.lastPathComponent, "main.swift")
        XCTAssertEqual(document.pendingCursor?.line, 2)
        XCTAssertEqual(document.pendingCursor?.column, 5)

        let missing = TerminalLinkMatch(kind: .path, target: "missing.swift", raw: "missing.swift")
        XCTAssertFalse(handler(missing, root, root))
    }

    @MainActor
    func testInstalledHandlerRoutesAbsoluteFileTargetIntoEditor() throws {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let settings = EditorSettings()
        let root = try temporaryDirectory()
        workspace.openWorkspace(root)
        let file = root.appendingPathComponent("absolute.swift")
        try "let absolute = true\n".write(to: file, atomically: true, encoding: .utf8)
        installTerminalLinkRouting(
            workspace: workspace,
            settings: settings,
            prompts: prompts(),
            openSystemURL: { _ in XCTFail("File targets must not open a browser") }
        )
        let handler = try XCTUnwrap(TerminalSession.detectedLinkHandler)

        let match = TerminalLinkMatch(kind: .path, target: file.path, raw: file.path)
        XCTAssertTrue(handler(match, root, root))
        XCTAssertEqual(workspace.selectedDocument?.url, file.standardizedFileURL)
    }

    @MainActor
    func testInstalledHandlerPromptsForURLsRegardlessOfConfiguration() throws {
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        let settings = EditorSettings()
        let root = try temporaryDirectory()
        workspace.openWorkspace(root)
        var openedSystemURLs: [URL] = []
        var choice: WebPublicURLChoice? = .system
        installTerminalLinkRouting(
            workspace: workspace,
            settings: settings,
            prompts: prompts(publicURLChoice: { _ in choice }),
            openSystemURL: { openedSystemURLs.append($0) }
        )
        let handler = try XCTUnwrap(TerminalSession.detectedLinkHandler)

        // Every terminal URL asks whether to use a fresh IDE tab or the system browser.
        let localhost = TerminalLinkMatch(
            kind: .url,
            target: "http://localhost:3000",
            raw: "http://localhost:3000"
        )
        XCTAssertTrue(handler(localhost, root, root))
        XCTAssertEqual(openedSystemURLs.map(\.absoluteString), ["http://localhost:3000"])

        settings.webView.openLocalhostURLs = false
        XCTAssertTrue(handler(localhost, root, root))
        XCTAssertEqual(
            openedSystemURLs.map(\.absoluteString),
            ["http://localhost:3000", "http://localhost:3000"]
        )

        // Public URLs prompt by default; the "system browser" choice opens externally.
        let publicMatch = TerminalLinkMatch(
            kind: .url,
            target: "https://example.com",
            raw: "https://example.com"
        )
        XCTAssertTrue(handler(publicMatch, root, root))
        XCTAssertEqual(
            openedSystemURLs.map(\.absoluteString),
            ["http://localhost:3000", "http://localhost:3000", "https://example.com"]
        )

        // The "local webview" choice opens a fresh, non-shared editor tab.
        choice = .webview
        XCTAssertTrue(handler(publicMatch, root, root))
        XCTAssertEqual(workspace.selectedWebTab?.urlString, "https://example.com")
        XCTAssertFalse(workspace.selectedWebTab?.isShared ?? true)
        XCTAssertEqual(openedSystemURLs.count, 3)

        // Config does not bypass the terminal's explicit destination choice.
        settings.webView.publicURLAction = .system
        XCTAssertTrue(handler(publicMatch, root, root))
        XCTAssertEqual(workspace.tabs.compactMap(\.web).count, 2)
        XCTAssertEqual(openedSystemURLs.count, 3)

        // HTML file targets remain editor documents.
        let page = root.appendingPathComponent("index.html")
        try "<p>hello</p>".write(to: page, atomically: true, encoding: .utf8)
        let htmlMatch = TerminalLinkMatch(kind: .path, target: "index.html", raw: "index.html")
        XCTAssertTrue(handler(htmlMatch, root, root))
        XCTAssertEqual(workspace.selectedDocument?.url, page.standardizedFileURL)

        settings.webView.openHTMLFiles = false
        XCTAssertTrue(handler(htmlMatch, root, root))
        XCTAssertEqual(workspace.selectedDocument?.url.lastPathComponent, "index.html")
    }

    // MARK: - Helpers

    private func prompts(
        target: @escaping (String, String, String) -> String? = { _, _, _ in nil },
        publicURLChoice: @escaping (URL) -> WebPublicURLChoice? = { _ in nil }
    ) -> WebViewPrompts {
        WebViewPrompts(target: target, publicURLChoice: publicURLChoice)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
