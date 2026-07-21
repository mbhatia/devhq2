import AppKit
import SwiftUI

@MainActor
final class CommandContextTracker: ObservableObject {
    @Published private(set) var activeView: CommandViewKind

    init(activeView: CommandViewKind = .worktree) {
        self.activeView = activeView
    }

    func activate(_ view: CommandViewKind) {
        activeView = view
    }

    func snapshot(workspace: WorkspaceModel) -> CommandContext {
        let selectedURL = workspace.selectedDocument?.url
        return CommandContext(
            view: activeView,
            worktreeURL: workspace.rootURL,
            fileURL: selectedURL,
            documentURL: selectedURL,
            terminalID: workspace.selectedTerminal?.id
        )
    }
}

struct ContentView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var worktreeExplorer: WorktreeExplorerModel
    @ObservedObject var settings: EditorSettings
    @ObservedObject var layout: WorkspaceLayoutModel
    @ObservedObject var commandManager: CommandManager
    @ObservedObject var commandPalette: CommandPaletteController
    @ObservedObject var commandContext: CommandContextTracker
    @ObservedObject var contextMenuRegistry: ContextMenuRegistry
    var tracksLayoutChanges = true
    @State private var hasRestoredLayout = false
    @State private var layoutRestorationRequestID = 0

    var body: some View {
        ZStack {
            HSplitView {
                if settings.treeViewVisible {
                    WorktreeExplorerSidebar(
                        explorer: worktreeExplorer,
                        workspace: workspace,
                        contextMenuRegistry: contextMenuRegistry
                    )
                        .frame(
                            minWidth: WorkspaceLayoutState.worktreeExplorerWidthRange.lowerBound,
                            idealWidth: layout.worktreeExplorerWidth,
                            maxWidth: WorkspaceLayoutState.worktreeExplorerWidthRange.upperBound
                        )
                        .background {
                            ZStack {
                                WorkspaceSplitViewRestorer(
                                    worktreeExplorerWidth: layout.worktreeExplorerWidth,
                                    fileExplorerWidth: layout.fileExplorerWidth,
                                    requestID: layoutRestorationRequestID
                                ) {
                                    if tracksLayoutChanges,
                                       abs(settings.treeViewSize - layout.fileExplorerWidth)
                                        >= WorkspaceLayoutModel.widthUpdateTolerance {
                                        settings.treeViewSize = layout.fileExplorerWidth
                                    }
                                    hasRestoredLayout = true
                                }

                                PaneWidthObserver { width in
                                    guard tracksLayoutChanges, hasRestoredLayout else { return }
                                    layout.updateWorktreeExplorerWidth(width)
                                }

                                PaneActivationMonitor(
                                    isEnabled: !commandPalette.isPresented
                                ) {
                                    commandContext.activate(.worktree)
                                }
                            }
                        }

                    Sidebar(
                        workspace: workspace,
                        contextMenuRegistry: contextMenuRegistry
                    )
                        .frame(
                            minWidth: WorkspaceLayoutState.fileExplorerWidthRange.lowerBound,
                            idealWidth: layout.fileExplorerWidth,
                            maxWidth: WorkspaceLayoutState.fileExplorerWidthRange.upperBound
                        )
                        .background {
                            ZStack {
                                PaneWidthObserver { width in
                                    guard tracksLayoutChanges, hasRestoredLayout else { return }
                                    layout.updateFileExplorerWidth(width)
                                    if abs(settings.treeViewSize - layout.fileExplorerWidth)
                                        >= WorkspaceLayoutModel.widthUpdateTolerance {
                                        settings.treeViewSize = layout.fileExplorerWidth
                                    }
                                }

                                PaneActivationMonitor(
                                    isEnabled: !commandPalette.isPresented
                                ) {
                                    commandContext.activate(.file)
                                }
                            }
                        }
                }

                EditorArea(workspace: workspace, settings: settings)
                    .frame(minWidth: 500, maxWidth: .infinity)
                    .background {
                        PaneActivationMonitor(isEnabled: !commandPalette.isPresented) {
                            commandContext.activate(
                                workspace.selectedTerminal == nil ? .document : .terminal
                            )
                        }
                    }
            }

            CommandPalette(controller: commandPalette)
        }
        .preferredColorScheme(settings.windowTheme.colorScheme)
        .onAppear {
            worktreeExplorer.syncSelection(with: workspace.rootURL)
            commandContext.activate(initialCommandView)
        }
        .onChange(of: workspace.rootURL) { rootURL in
            worktreeExplorer.syncSelection(with: rootURL)
            commandContext.activate(initialCommandView)
        }
        .onChange(of: workspace.selectedTabID) { _ in
            commandContext.activate(workspace.selectedTerminal == nil ? .document : .terminal)
        }
        .onChange(of: settings.treeViewSize) { width in
            guard tracksLayoutChanges,
                  !settings.treeViewVisible || hasRestoredLayout else { return }
            layout.updateFileExplorerWidth(width)
        }
        .onChange(of: settings.treeViewVisible) { isVisible in
            hasRestoredLayout = false
            if isVisible {
                layoutRestorationRequestID += 1
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    workspace.chooseFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
                Button {
                    workspace.saveSelected()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(workspace.selectedDocument == nil)
            }
        }
        .alert(
            "DevHQ",
            isPresented: Binding(
                get: {
                    workspace.errorMessage != nil
                        || worktreeExplorer.errorMessage != nil
                        || settings.pluginError != nil
                        || layout.errorMessage != nil
                },
                set: {
                    if !$0 {
                        workspace.errorMessage = nil
                        worktreeExplorer.clearError()
                        settings.pluginError = nil
                        layout.clearError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                workspace.errorMessage = nil
                worktreeExplorer.clearError()
                settings.pluginError = nil
                layout.clearError()
            }
        } message: {
            Text(
                workspace.errorMessage
                    ?? worktreeExplorer.errorMessage
                    ?? settings.pluginError
                    ?? layout.errorMessage
                    ?? "Unknown error"
            )
        }
    }

    private var initialCommandView: CommandViewKind {
        if workspace.selectedTerminal != nil { return .terminal }
        if workspace.selectedDocument != nil { return .document }
        if workspace.rootURL != nil { return .file }
        return .worktree
    }
}

private struct PaneWidthObserver: View {
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear {
                    onChange(geometry.size.width)
                }
                .onChange(of: geometry.size.width) { width in
                    onChange(width)
                }
        }
    }
}

/// Observes pane clicks without adding a SwiftUI gesture above AppKit-backed
/// editor views or participating in hit testing.
private struct PaneActivationMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onActivate: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onActivate: onActivate)
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView(frame: .zero)
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onActivate = onActivate
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    final class Coordinator {
        var isEnabled: Bool
        var onActivate: () -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(isEnabled: Bool, onActivate: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onActivate = onActivate
        }

        deinit {
            uninstall()
        }

        func install(for view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self,
                      self.isEnabled,
                      let view = self.view,
                      event.window === view.window,
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil))
                else { return event }

                // The deferred repeat keeps the pane click authoritative when
                // its action also opens or restores a document.
                self.onActivate()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isEnabled else { return }
                    self.onActivate()
                }
                return event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

private struct WorktreeExplorerSidebar: View {
    @ObservedObject var explorer: WorktreeExplorerModel
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var contextMenuRegistry: ContextMenuRegistry

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text("Worktree Explorer")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button(action: chooseRepository) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add Local Git Repository")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            if explorer.repositories.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No Repositories").font(.title3.weight(.semibold))
                    Text("Add a local Git repository to browse its worktrees.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Add Local Git Repository…", action: chooseRepository)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    TreeView(
                        model: explorer.tree,
                        selectedID: explorer.selectedNodeID,
                        onToggle: { node in explorer.toggle(node) },
                        isBranchSelectable: { node in
                            if case .worktree = node.value { return true }
                            return false
                        },
                        contextMenuProvider: { node in
                            guard let snapshot = worktreeContextMenuSnapshot(
                                for: node,
                                in: explorer
                            ) else { return [] }
                            return treeContextMenuEntries(
                                for: snapshot,
                                registry: contextMenuRegistry,
                                onError: explorer.reportError
                            )
                        }
                    ) { node in
                        explorer.activate(node)
                    } rowContent: { node in
                        WorktreeExplorerRow(
                            node: node,
                            profile: agentProfile(for: node),
                            isSelected: explorer.selectedNodeID == node.id
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Add Local Git Repository"
        panel.prompt = "Add Repository"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try explorer.addRepository(url)
            explorer.syncSelection(with: workspace.rootURL)
        } catch {
            // The explorer publishes operation errors through errorMessage.
        }
    }

    private func agentProfile(for node: WorktreeNode) -> AgentProfile? {
        guard case .agent(let agent) = node.value else { return nil }
        return explorer.profile(for: agent)
    }
}

private struct WorktreeExplorerRow: View {
    let node: WorktreeNode
    let profile: AgentProfile?
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if case .agent = node.value {
                Text(profile?.icon ?? "@")
                    .font(agentIconFont)
                    .foregroundStyle(agentIconColor)
                    .frame(width: 16)
            } else {
                Image(systemName: iconName)
            }
            Text(node.value.name)
        }
            .lineLimit(1)
            .help(node.value.url.path)
            .padding(.vertical, 3)
            .onHover { isHovered = $0 }
    }

    private var iconName: String {
        switch node.value {
        case .repository: "externaldrive"
        case .worktree: "arrow.triangle.branch"
        case .agent: "at"
        }
    }

    private var agentIconFont: Font {
        switch profile?.iconFont ?? .system {
        case .system: .system(size: 12, weight: .semibold)
        }
    }

    private var agentIconColor: Color {
        if profile?.iconColor == .accent { return .accentColor }
        guard case .agent(let agent) = node.value else { return .secondary }
        if agent.needsInput { return Color(nsColor: .systemOrange) }
        if isSelected || isHovered { return .accentColor }
        return .secondary
    }
}

private struct Sidebar: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var contextMenuRegistry: ContextMenuRegistry

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "externaldrive")
                    .foregroundStyle(.secondary)
                Text(workspace.rootURL?.lastPathComponent ?? "No Folder Open")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            if workspace.rootURL == nil {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("Open a Folder").font(.title3.weight(.semibold))
                    Text("Choose a project folder to browse its files.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Folder…") { workspace.chooseFolder() }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    TreeView(
                        model: workspace.fileTree,
                        selectedID: workspace.selectedFileNodeID,
                        contextMenuProvider: { node in
                            treeContextMenuEntries(
                                for: fileContextMenuSnapshot(for: node),
                                registry: contextMenuRegistry
                            ) { error in
                                workspace.errorMessage = error.localizedDescription
                            }
                        }
                    ) { node in
                        workspace.open(node)
                    } rowContent: { node in
                        FileRow(node: node)
                    }
                    .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct FileRow: View {
    let node: FileNode

    var body: some View {
        Label(node.name, systemImage: iconName)
            .lineLimit(1)
            .help(node.url.path)
            .padding(.vertical, 3)
    }

    private var iconName: String {
        if node.isDirectory { return "folder" }
        switch node.url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "md": return "doc.richtext"
        case "json", "yml", "yaml", "toml": return "curlybraces"
        default: return "doc.plaintext"
        }
    }
}

private struct EditorArea: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var settings: EditorSettings

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty {
                TabStrip(workspace: workspace)
                    .fixedSize(horizontal: false, vertical: true)
                    .zIndex(1)
                Divider()
                    .zIndex(1)
            }

            Group {
                if let document = workspace.selectedDocument {
                    FileEditor(document: document, settings: settings)
                        .id(document.id)
                } else if let terminal = workspace.selectedTerminal {
                    TerminalView(session: terminal)
                        .id(terminal.id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("No Tab Open").font(.title2.weight(.semibold))
                        Text("Select a file or open a terminal.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .clipped()
    }
}

private struct TabStrip: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(workspace.tabs) { tab in
                    switch tab {
                    case .document(let document):
                        TabButton(
                            document: document,
                            isSelected: workspace.selectedTabID == document.id,
                            select: { workspace.select(document) },
                            close: { workspace.close(document) }
                        )
                    case .terminal(let terminal):
                        TerminalTabButton(
                            terminal: terminal,
                            isSelected: workspace.selectedTabID == terminal.id,
                            select: { workspace.select(terminal) },
                            close: { workspace.close(terminal) }
                        )
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 38)
        .background(.bar)
    }
}

private struct TerminalTabButton: View {
    @ObservedObject var terminal: TerminalSession
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(terminal.displayTitle)
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected { Color.accentColor.frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

private struct TabButton: View {
    @ObservedObject var document: EditorDocument
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: document.url.pathExtension == "swift" ? "swift" : "doc.text")
                .foregroundStyle(.secondary)
            Text(document.url.lastPathComponent + (document.isDirty ? " •" : ""))
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected { Color.accentColor.frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

private struct FileEditor: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var settings: EditorSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SourceEditorView(
            text: Binding(get: { document.text }, set: { document.text = $0 }),
            language: document.language,
            isDark: colorScheme == .dark,
            showGutter: settings.showGutter,
            showMinimap: settings.showMinimap,
            showFoldingRibbon: settings.showFoldingRibbon
        )
    }
}
