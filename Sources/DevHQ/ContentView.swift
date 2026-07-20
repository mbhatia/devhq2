import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var worktreeExplorer: WorktreeExplorerModel
    @ObservedObject var settings: EditorSettings

    var body: some View {
        HSplitView {
            if settings.treeViewVisible {
                WorktreeExplorerSidebar(explorer: worktreeExplorer, workspace: workspace)
                    .frame(minWidth: 190, idealWidth: 240, maxWidth: 480)

                Sidebar(workspace: workspace)
                    .frame(minWidth: 190, idealWidth: settings.treeViewSize, maxWidth: 600)
            }

            EditorArea(workspace: workspace, settings: settings)
                .frame(minWidth: 500)
        }
        .preferredColorScheme(settings.windowTheme.colorScheme)
        .onAppear {
            worktreeExplorer.syncSelection(with: workspace.rootURL)
        }
        .onChange(of: workspace.rootURL) { rootURL in
            worktreeExplorer.syncSelection(with: rootURL)
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
                },
                set: {
                    if !$0 {
                        workspace.errorMessage = nil
                        worktreeExplorer.clearError()
                        settings.pluginError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                workspace.errorMessage = nil
                worktreeExplorer.clearError()
                settings.pluginError = nil
            }
        } message: {
            Text(
                workspace.errorMessage
                    ?? worktreeExplorer.errorMessage
                    ?? settings.pluginError
                    ?? "Unknown error"
            )
        }
    }
}

private struct WorktreeExplorerSidebar: View {
    @ObservedObject var explorer: WorktreeExplorerModel
    @ObservedObject var workspace: WorkspaceModel

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
                        onToggle: { node in explorer.toggle(node) }
                    ) { node in
                        explorer.activate(node)
                    } rowContent: { node in
                        WorktreeExplorerRow(node: node)
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
}

private struct WorktreeExplorerRow: View {
    let node: WorktreeNode

    var body: some View {
        Label(node.value.name, systemImage: iconName)
            .lineLimit(1)
            .help(node.value.url.path)
            .padding(.vertical, 3)
    }

    private var iconName: String {
        switch node.value {
        case .repository: "externaldrive"
        case .worktree: "arrow.triangle.branch"
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var workspace: WorkspaceModel

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
                        selectedID: workspace.selectedFileNodeID
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
            if !workspace.documents.isEmpty {
                TabStrip(workspace: workspace)
                Divider()
            }

            if let document = workspace.selectedDocument {
                FileEditor(document: document, settings: settings)
                    .id(document.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("No File Open").font(.title2.weight(.semibold))
                    Text("Select a file from the project navigator.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct TabStrip: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(workspace.documents) { document in
                    TabButton(
                        document: document,
                        isSelected: workspace.selectedDocumentID == document.id,
                        select: { workspace.select(document) },
                        close: { workspace.close(document) }
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 38)
        .background(.bar)
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
