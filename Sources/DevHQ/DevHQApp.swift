import AppKit
import CodeEditTextView
import Foundation
import SwiftUI

@MainActor
final class DevHQApplicationDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        terminationHandler?()
    }
}

@main
struct DevHQApp: App {
    @NSApplicationDelegateAdaptor(DevHQApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var commandManager: CommandManager
    @StateObject private var commandPalette: CommandPaletteController
    @StateObject private var commandContext: CommandContextTracker
    @StateObject private var workspace: WorkspaceModel
    @StateObject private var worktreeExplorer: WorktreeExplorerModel
    @StateObject private var plugins: LuaPluginHost
    @StateObject private var layout: WorkspaceLayoutModel
    private static var snapshotWindow: NSWindow?

    init() {
        let commandManager = CommandManager()
        let commandPalette = CommandPaletteController(commandManager: commandManager)
        let commandContext = CommandContextTracker()
        let plugins = LuaPluginHost(commandManager: commandManager)
        let stateStore = WorkspaceStateStore()
        let workspace = WorkspaceModel(stateStore: stateStore)
        let worktreeExplorer = WorktreeExplorerModel(
            discoverer: LibGit2WorktreeService(),
            onActivate: { repository, worktree in
                workspace.openWorktree(
                    canonicalRepositoryName: repository.canonicalName,
                    worktreeName: worktree.name,
                    url: worktree.url
                )
            },
            onSelectionIdentityChange: { repository, worktree in
                workspace.updateCurrentWorktreeIdentity(
                    canonicalRepositoryName: repository.canonicalName,
                    worktreeName: worktree.name,
                    url: worktree.url
                )
            },
            stateStore: stateStore
        )
        do {
            try registerBuiltInCommands(
                in: commandManager,
                workspace: workspace,
                worktreeExplorer: worktreeExplorer
            )
        } catch {
            plugins.settings.pluginError =
                "Could not register built-in commands: \(error.localizedDescription)"
        }
        plugins.loadUserConfiguration()
        let layout = WorkspaceLayoutModel(
            fileExplorerFallbackWidth: plugins.settings.treeViewSize
        )
        let hasExplicitCommandLineWorkspace = Self.argumentValue(after: "--workspace") != nil
        worktreeExplorer.restore(activateSelection: !hasExplicitCommandLineWorkspace)
        if hasExplicitCommandLineWorkspace {
            worktreeExplorer.syncSelection(with: workspace.rootURL)
        }
        _commandManager = StateObject(wrappedValue: commandManager)
        _commandPalette = StateObject(wrappedValue: commandPalette)
        _commandContext = StateObject(wrappedValue: commandContext)
        _workspace = StateObject(wrappedValue: workspace)
        _worktreeExplorer = StateObject(wrappedValue: worktreeExplorer)
        _plugins = StateObject(wrappedValue: plugins)
        _layout = StateObject(wrappedValue: layout)
        applicationDelegate.terminationHandler = {
            workspace.saveCurrentWorkspaceState()
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
        WindowGroup("DevHQ") {
            ContentView(
                workspace: workspace,
                worktreeExplorer: worktreeExplorer,
                settings: plugins.settings,
                layout: layout,
                commandManager: commandManager,
                commandPalette: commandPalette,
                commandContext: commandContext
            )
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    workspace.chooseFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    workspace.saveSelected()
                }
                .keyboardShortcut("s")
                .disabled(workspace.selectedDocument == nil)
            }
            CommandGroup(after: .saveItem) {
                Button("Command Palette…") {
                    commandPalette.present(
                        in: commandContext.snapshot(workspace: workspace)
                    )
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
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
        let worktreeExplorer = WorktreeExplorerModel(
            discoverer: LibGit2WorktreeService(),
            onActivate: { worktree in model.openWorkspace(worktree.url) }
        )
        do {
            try registerBuiltInCommands(
                in: commandManager,
                workspace: model,
                worktreeExplorer: worktreeExplorer
            )
        } catch {
            model.errorMessage =
                "Could not register built-in commands: \(error.localizedDescription)"
        }
        let content = ContentView(
            workspace: model,
            worktreeExplorer: worktreeExplorer,
            settings: settings,
            layout: layout,
            commandManager: commandManager,
            commandPalette: commandPalette,
            commandContext: commandContext,
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
        window.title = "DevHQ"
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
