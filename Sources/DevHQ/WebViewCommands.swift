import AppKit
import Foundation

enum WebPublicURLChoice {
    case webview
    case system
}

/// AppKit prompt seams for the web commands, injectable for tests like
/// `BuiltInCommandPickers`.
struct WebViewPrompts {
    var target: (_ title: String, _ message: String, _ initialValue: String) -> String?
    var publicURLChoice: (_ url: URL) -> WebPublicURLChoice?

    init(
        target: @escaping (_ title: String, _ message: String, _ initialValue: String) -> String?,
        publicURLChoice: @escaping (_ url: URL) -> WebPublicURLChoice?
    ) {
        self.target = target
        self.publicURLChoice = publicURLChoice
    }

    static let appKit = WebViewPrompts(
        target: { title, message, initialValue in
            let field = NSTextField(string: initialValue)
            field.placeholderString = "https://example.com or ~/page.html"
            field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)

            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        },
        publicURLChoice: { url in
            let alert = NSAlert()
            alert.messageText = "Open URL"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "Local Webview")
            alert.addButton(withTitle: "System Browser")
            alert.addButton(withTitle: "Cancel")
            return switch alert.runModal() {
            case .alertFirstButtonReturn: .webview
            case .alertSecondButtonReturn: .system
            default: nil
            }
        }
    )
}

/// Opens a new web preview tab for `target` and selects it.
@MainActor
@discardableResult
func openWebTab(
    _ target: String,
    in workspace: WorkspaceModel,
    configuration: WebViewConfiguration
) -> WebViewTab {
    let tab = WebViewTab(
        target: target,
        homeURL: configuration.homeURL,
        baseDirectory: workspace.rootURL?.path
    )
    workspace.addWebTab(tab)
    return tab
}

/// Navigates the worktree's shared web preview tab to `target`, creating the
/// tab on first use, and selects it. The shared tab parks and restores with
/// the worktree's editor session like terminals do.
@MainActor
@discardableResult
func openSharedWebTarget(
    _ target: String,
    in workspace: WorkspaceModel,
    configuration: WebViewConfiguration
) -> WebViewTab {
    if let shared = workspace.sharedWebTab {
        shared.navigate(
            to: target,
            homeURL: configuration.homeURL,
            baseDirectory: workspace.rootURL?.path
        )
        workspace.select(shared)
        return shared
    }
    let tab = WebViewTab(
        target: target,
        homeURL: configuration.homeURL,
        baseDirectory: workspace.rootURL?.path,
        isShared: true
    )
    workspace.addWebTab(tab)
    return tab
}

@MainActor
func registerWebViewCommands(
    in commandManager: CommandManager,
    workspace: WorkspaceModel,
    settings: EditorSettings,
    prompts: WebViewPrompts = .appKit
) throws {
    let workspaceAvailable: RegisteredCommand.Predicate = { _ in
        workspace.rootURL != nil
    }
    let webTabSelected: RegisteredCommand.Predicate = { _ in
        workspace.selectedWebTab != nil
    }

    try commandManager.add(
        id: "web:open-url",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: workspaceAvailable
    ) { _ in
        guard let input = prompts.target(
            "Open URL or File",
            "Enter a URL or a local file path.",
            settings.webView.homeURL
        ), !input.isEmpty else { return }
        openWebTab(input, in: workspace, configuration: settings.webView)
    }

    try commandManager.add(
        id: "web:open-localhost",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: workspaceAvailable
    ) { _ in
        guard let input = prompts.target(
            "Open Local Web App",
            "Enter the local development server URL.",
            settings.webView.localhostURL
        ), !input.isEmpty else { return }
        openWebTab(input, in: workspace, configuration: settings.webView)
    }

    try commandManager.add(
        id: "web:open-active-file",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: workspaceAvailable
    ) { _ in
        if let url = workspace.selectedDocument?.url {
            openWebTab(url.path, in: workspace, configuration: settings.webView)
            return
        }
        guard let input = prompts.target(
            "Open HTML File or URL",
            "Enter a URL or a local file path.",
            settings.webView.homeURL
        ), !input.isEmpty else { return }
        openWebTab(input, in: workspace, configuration: settings.webView)
    }

    try commandManager.add(
        id: "devhq:open-webview",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: workspaceAvailable
    ) { _ in
        guard let input = prompts.target(
            "Open URL or HTML File",
            "Enter a URL or a local HTML file path.",
            ""
        ), !input.isEmpty else { return }
        openSharedWebTarget(input, in: workspace, configuration: settings.webView)
    }

    try commandManager.add(
        id: "web:set-location",
        viewKinds: [.web],
        predicate: webTabSelected
    ) { _ in
        guard let tab = workspace.selectedWebTab,
              let input = prompts.target(
                  "Web Location",
                  "Enter a URL or a local file path.",
                  tab.urlString
              ), !input.isEmpty else { return }
        tab.navigate(
            to: input,
            homeURL: settings.webView.homeURL,
            baseDirectory: workspace.rootURL?.path
        )
    }

    try commandManager.add(
        id: "web:reload",
        viewKinds: [.web],
        predicate: webTabSelected
    ) { _ in
        workspace.selectedWebTab?.reload()
    }

    try commandManager.add(
        id: "web:back",
        viewKinds: [.web],
        predicate: webTabSelected
    ) { _ in
        workspace.selectedWebTab?.goBack()
    }

    try commandManager.add(
        id: "web:forward",
        viewKinds: [.web],
        predicate: webTabSelected
    ) { _ in
        workspace.selectedWebTab?.goForward()
    }

    try commandManager.add(
        id: "web:copy-url",
        viewKinds: [.web],
        predicate: webTabSelected
    ) { _ in
        guard let tab = workspace.selectedWebTab else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tab.urlString, forType: .string)
    }

    try commandManager.add(
        id: "web:close",
        viewKinds: [.web],
        predicate: webTabSelected
    ) { _ in
        guard let tab = workspace.selectedWebTab else { return }
        workspace.close(tab)
    }
}

/// Routes Cmd-clicked terminal links (pattern-detected, not OSC 8) into the
/// editor, the shared webview, or the system browser per `config.webview`.
/// The webview never takes keyboard focus on navigation, so terminal typing
/// resumes as soon as the terminal tab is active again.
@MainActor
func installTerminalLinkRouting(
    workspace: WorkspaceModel,
    settings: EditorSettings,
    prompts: WebViewPrompts = .appKit,
    openSystemURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
) {
    TerminalSession.detectedLinkHandler = {
        [weak workspace, weak settings] match, currentDirectory, rootURL in
        guard let workspace, let settings else { return false }
        let configuration = settings.webView
        let route = TerminalLinkRouter.route(
            match,
            configuration: configuration,
            currentDirectory: currentDirectory.path,
            workspaceRoot: rootURL.path,
            isFile: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
        )
        switch route {
        case let .editor(path, line, column):
            let url = URL(fileURLWithPath: path)
            if let line {
                workspace.openFile(url, line: line, column: column)
            } else {
                workspace.openFile(url)
            }
            return true
        case let .webview(target):
            openWebTab(target, in: workspace, configuration: configuration)
            return true
        case let .system(url):
            openSystemURL(url)
            return true
        case let .prompt(url):
            switch prompts.publicURLChoice(url) {
            case .webview:
                openWebTab(
                    url.absoluteString,
                    in: workspace,
                    configuration: configuration
                )
            case .system:
                openSystemURL(url)
            case nil:
                break
            }
            return true
        case .unhandled:
            return false
        }
    }
}
