import AppKit
import CodeEditTextView
import Foundation
import SwiftUI

private let devHQApplicationName = ProcessInfo.processInfo.environment["DEVHQ_APP_NAME"]
    .flatMap { $0.isEmpty ? nil : $0 }
    ?? "DevHQ"

@MainActor
final class DevHQApplicationDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        terminationHandler?()
    }
}

// The entry point is `DevHQMain` (ReviewReplyCLI.swift), which dispatches
// headless `devhq review …` invocations before launching the app.
struct DevHQApp: App {
    @NSApplicationDelegateAdaptor(DevHQApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var commandManager: CommandManager
    @StateObject private var commandPalette: CommandPaletteController
    @StateObject private var commandContext: CommandContextTracker
    @StateObject private var workspace: WorkspaceModel
    @StateObject private var worktreeExplorer: WorktreeExplorerModel
    @StateObject private var plugins: LuaPluginHost
    @StateObject private var agentManager: AgentManager
    @StateObject private var layout: WorkspaceLayoutModel
    @StateObject private var terminalDrawer: TerminalDrawerModel
    @StateObject private var sidebarVisibility: SidebarVisibilityModel
    @StateObject private var commentThreads: CommentThreadsController
    private static var snapshotWindow: NSWindow?

    init() {
        let commandManager = CommandManager()
        let commandPalette = CommandPaletteController(commandManager: commandManager)
        let commandContext = CommandContextTracker()
        let stateStore = WorkspaceStateStore()
        let gitQuery = GitQueryService()
        let workspace = WorkspaceModel(stateStore: stateStore, gitQuery: gitQuery)
        let plugins = LuaPluginHost(commandManager: commandManager, workspace: workspace)
        let agentManager = AgentManager(
            workspace: workspace,
            profiles: plugins.agentProfileRegistry,
            patternMatcher: plugins
        )
        let worktreeService = LibGit2WorktreeService()
        let remoteRepositoryService = SSHRemoteRepositoryService(
            mutationProtection: { _, localWorktreeURLs in
                await MainActor.run {
                    !localWorktreeURLs.contains {
                        workspace.hasUnsavedChanges(inWorkspaceAt: $0)
                    }
                }
            }
        )
        let worktreeExplorer = WorktreeExplorerModel(
            discoverer: worktreeService,
            remoteService: remoteRepositoryService,
            onActivate: { repository, worktree in
                workspace.openWorktree(
                    canonicalRepositoryName: repository.canonicalName,
                    worktreeName: worktree.name,
                    url: worktree.url,
                    remoteSource: repository.remoteSource,
                    remotePath: worktree.remotePath
                )
            },
            onSelectionIdentityChange: { repository, worktree in
                workspace.updateCurrentWorktreeIdentity(
                    canonicalRepositoryName: repository.canonicalName,
                    worktreeName: worktree.name,
                    url: worktree.url
                )
            },
            onWorktreeRemoved: { _, worktree in
                guard workspace.rootURL == worktree.url.standardizedFileURL.resolvingSymlinksInPath()
                else { return }
                if workspace.hasUnsavedChanges(inWorkspaceAt: worktree.url) {
                    workspace.errorMessage =
                        "The remote worktree was removed while it still has unsaved editor changes."
                } else {
                    workspace.closeWorkspace(at: worktree.url)
                }
            },
            shouldSynchronizeRemoteRepository: { repository in
                !repository.worktrees.contains {
                    workspace.hasUnsavedChanges(inWorkspaceAt: $0.url)
                }
            },
            agentManager: agentManager,
            onActivateAgent: { agent, repository, worktree in
                try agentManager.activate(
                    agent.key,
                    repository: repository,
                    worktree: worktree
                )
            },
            stateStore: stateStore
        )
        registerBuiltInContextMenus(
            in: plugins.contextMenuRegistry,
            workspace: workspace,
            worktreeExplorer: worktreeExplorer,
            settings: plugins.settings,
            worktreeManager: worktreeService
        )
        let terminalDrawer = TerminalDrawerModel()
        let sidebarVisibility = SidebarVisibilityModel()
        do {
            try registerBuiltInCommands(
                in: commandManager,
                workspace: workspace,
                worktreeExplorer: worktreeExplorer,
                agentManager: agentManager,
                agentProfiles: plugins.agentProfileRegistry
            )
            try registerCommandParityCommands(
                in: commandManager,
                workspace: workspace,
                worktreeExplorer: worktreeExplorer,
                settings: plugins.settings,
                worktreeManager: worktreeService,
                terminalDrawer: terminalDrawer,
                sidebarVisibility: sidebarVisibility
            )
        } catch {
            plugins.settings.pluginError =
                "Could not register built-in commands: \(error.localizedDescription)"
        }
        do {
            try registerApplicationCommands(
                in: commandManager,
                workspace: workspace,
                commandPalette: commandPalette,
                commandContext: commandContext
            )
            try KeyBindingRegistry.shared.setDefaultBindings([
                KeyBinding(shortcut: "cmd+shift+o", commandID: "workspace:open-folder"),
                KeyBinding(shortcut: "cmd+s", commandID: "workspace:save"),
                KeyBinding(shortcut: "control+shift+`", commandID: "terminal:new"),
                KeyBinding(shortcut: "cmd+w", commandID: "terminal:close"),
                KeyBinding(shortcut: "option+t", commandID: "terminal:toggle-drawer"),
                KeyBinding(shortcut: "cmd+shift+p", commandID: "devhq:command-palette")
            ])
        } catch {
            plugins.settings.pluginError =
                "Could not register application key bindings: \(error.localizedDescription)"
        }
        do {
            try registerWebViewCommands(
                in: commandManager,
                workspace: workspace,
                settings: plugins.settings
            )
        } catch {
            plugins.settings.pluginError =
                "Could not register web commands: \(error.localizedDescription)"
        }
        installTerminalLinkRouting(workspace: workspace, settings: plugins.settings)
        let commentThreads = CommentThreadsController(
            workspace: workspace,
            agentManager: agentManager
        )
        commentThreads.makeActive()
        commentThreads.startWatching()
        do {
            try registerReviewCommentCommands(
                in: commandManager,
                workspace: workspace,
                comments: commentThreads
            )
        } catch {
            plugins.settings.pluginError =
                "Could not register review comment commands: \(error.localizedDescription)"
        }
        let hasExplicitCommandLineWorkspace = Self.argumentValue(after: "--workspace") != nil
        worktreeExplorer.restore(activateSelection: !hasExplicitCommandLineWorkspace)
        if hasExplicitCommandLineWorkspace {
            worktreeExplorer.syncSelection(with: workspace.rootURL)
        }
        plugins.loadUserConfiguration()
        let layout = WorkspaceLayoutModel(
            fileExplorerFallbackWidth: plugins.settings.treeViewSize
        )
        _commandManager = StateObject(wrappedValue: commandManager)
        _commandPalette = StateObject(wrappedValue: commandPalette)
        _commandContext = StateObject(wrappedValue: commandContext)
        _workspace = StateObject(wrappedValue: workspace)
        _worktreeExplorer = StateObject(wrappedValue: worktreeExplorer)
        _plugins = StateObject(wrappedValue: plugins)
        _agentManager = StateObject(wrappedValue: agentManager)
        _layout = StateObject(wrappedValue: layout)
        _terminalDrawer = StateObject(wrappedValue: terminalDrawer)
        _sidebarVisibility = StateObject(wrappedValue: sidebarVisibility)
        _commentThreads = StateObject(wrappedValue: commentThreads)
        applicationDelegate.terminationHandler = {
            agentManager.prepareForTermination()
            workspace.saveCurrentWorkspaceState()
            workspace.closeAllTerminals()
            terminalDrawer.terminate()
        }

        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.async {
                Self.prepareSnapshotWindow(settings: plugins.settings, layout: layout)
                if let line = Self.argumentValue(after: "--fold-line").flatMap(Int.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        Self.foldLine(line)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    Self.captureWindow(at: path)
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup(devHQApplicationName) {
            ContentView(
                workspace: workspace,
                worktreeExplorer: worktreeExplorer,
                settings: plugins.settings,
                layout: layout,
                commandManager: commandManager,
                commandPalette: commandPalette,
                commandContext: commandContext,
                keyBindingRouter: KeyBindingRouter(
                    commandManager: commandManager,
                    context: { commandContext.snapshot(workspace: workspace) },
                    reportError: { workspace.errorMessage = $0.localizedDescription }
                ),
                contextMenuRegistry: plugins.contextMenuRegistry,
                terminalDrawer: terminalDrawer,
                sidebarVisibility: sidebarVisibility,
                reviewComments: commentThreads
            )
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    workspace.chooseFolder()
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    workspace.saveSelected()
                }
                .disabled(workspace.selectedDocument?.isReadOnly != false)
            }
            CommandGroup(after: .saveItem) {
                Button("New Terminal") {
                    do {
                        _ = try workspace.newTerminal()
                    } catch {
                        workspace.errorMessage = error.localizedDescription
                    }
                }
                .disabled(workspace.rootURL == nil)

                Button("Close Terminal") {
                    if let terminal = workspace.selectedTerminal { workspace.close(terminal) }
                }
                .disabled(workspace.selectedTerminal == nil)

                Button("Toggle Terminal Drawer") {
                    do {
                        try terminalDrawer.toggle(activeWorktree: workspace.rootURL)
                    } catch {
                        workspace.errorMessage = error.localizedDescription
                    }
                }
                .disabled(workspace.rootURL == nil && terminalDrawer.session == nil)

                Button("Command Palette…") {
                    commandPalette.present(
                        in: commandContext.snapshot(workspace: workspace)
                    )
                }
            }
        }
    }

    private static func prepareSnapshotWindow(
        settings: EditorSettings,
        layout: WorkspaceLayoutModel
    ) {
        let commandManager = CommandManager()
        let commandPalette = CommandPaletteController(commandManager: commandManager)
        let commandContext = CommandContextTracker()
        let model = WorkspaceModel()
        let contextMenuRegistry = ContextMenuRegistry()
        let worktreeService = LibGit2WorktreeService()
        let worktreeExplorer = WorktreeExplorerModel(
            discoverer: worktreeService,
            onActivate: { worktree in model.openWorkspace(worktree.url) }
        )
        registerBuiltInContextMenus(
            in: contextMenuRegistry,
            workspace: model,
            worktreeExplorer: worktreeExplorer,
            settings: settings,
            worktreeManager: worktreeService
        )
        do {
            try registerBuiltInCommands(
                in: commandManager,
                workspace: model,
                worktreeExplorer: worktreeExplorer
            )
            try registerApplicationCommands(
                in: commandManager,
                workspace: model,
                commandPalette: commandPalette,
                commandContext: commandContext
            )
        } catch {
            model.errorMessage =
                "Could not register snapshot commands: \(error.localizedDescription)"
        }
        let content = ContentView(
            workspace: model,
            worktreeExplorer: worktreeExplorer,
            settings: settings,
            layout: layout,
            commandManager: commandManager,
            commandPalette: commandPalette,
            commandContext: commandContext,
            keyBindingRouter: KeyBindingRouter(
                commandManager: commandManager,
                context: { commandContext.snapshot(workspace: model) },
                reportError: { model.errorMessage = $0.localizedDescription }
            ),
            contextMenuRegistry: contextMenuRegistry,
            reviewComments: CommentThreadsController(workspace: model),
            tracksLayoutChanges: false
        )
            .frame(width: 1200, height: 760)
        let hostingView = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = devHQApplicationName
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        snapshotWindow = window
    }

    private static func foldLine(_ line: Int) {
        guard line > 0,
              let window = snapshotWindow,
              let contentView = window.contentView,
              let ribbon = findSubview(named: "LineFoldRibbonView", in: contentView),
              let textView = findSubview(ofType: TextView.self, in: contentView),
              let linePosition = textView.layoutManager.textLineForIndex(line - 1) else { return }

        let point = ribbon.convert(
            NSPoint(x: ribbon.bounds.midX, y: linePosition.yPos + (linePosition.height / 2)),
            to: nil
        )
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }
        ribbon.mouseDown(with: event)
        contentView.layoutSubtreeIfNeeded()
    }

    private static func findSubview(named name: String, in view: NSView) -> NSView? {
        if String(describing: type(of: view)).hasSuffix(name) {
            return view
        }
        return view.subviews.lazy.compactMap { findSubview(named: name, in: $0) }.first
    }

    private static func findSubview<T: NSView>(ofType type: T.Type, in view: NSView) -> T? {
        if let view = view as? T {
            return view
        }
        return view.subviews.lazy.compactMap { findSubview(ofType: type, in: $0) }.first
    }

    private static func argumentValue(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func captureWindow(at path: String) {
        guard let window = snapshotWindow,
              let view = window.contentView else { return }
        window.setContentSize(NSSize(width: 1200, height: 760))
        view.layoutSubtreeIfNeeded()
        let width = max(Int(view.bounds.width * 2), 2)
        let height = max(Int(view.bounds.height * 2), 2)
        guard let image = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        image.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
private func registerApplicationCommands(
    in commandManager: CommandManager,
    workspace: WorkspaceModel,
    commandPalette: CommandPaletteController,
    commandContext: CommandContextTracker
) throws {
    try commandManager.add(
        id: "workspace:open-folder",
        viewKinds: Set(CommandViewKind.allCases)
    ) { _ in
        workspace.chooseFolder()
    }

    try commandManager.add(
        id: "workspace:save",
        viewKinds: Set(CommandViewKind.allCases),
        predicate: { _ in workspace.selectedDocument?.isReadOnly == false }
    ) { _ in
        workspace.saveSelected()
    }

    try commandManager.add(
        id: "devhq:command-palette",
        viewKinds: Set(CommandViewKind.allCases)
    ) { _ in
        commandPalette.present(in: commandContext.snapshot(workspace: workspace))
    }
}
