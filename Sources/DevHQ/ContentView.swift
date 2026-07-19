import SwiftUI

struct ContentView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        HSplitView {
            Sidebar(workspace: workspace)
                .frame(minWidth: 190, idealWidth: 250, maxWidth: 380)
            EditorArea(workspace: workspace)
                .frame(minWidth: 600)
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
                get: { workspace.errorMessage != nil },
                set: { if !$0 { workspace.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { workspace.errorMessage = nil }
        } message: {
            Text(workspace.errorMessage ?? "Unknown error")
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
                    FileTree(nodes: workspace.nodes, workspace: workspace)
                        .padding(.vertical, 6)
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct FileTree: View {
    let nodes: [FileNode]
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(nodes) { node in
                if let children = node.children {
                    DisclosureGroup(isExpanded: .constant(true)) {
                        FileTree(nodes: children, workspace: workspace)
                            .padding(.leading, 12)
                    } label: {
                        FileRow(node: node)
                    }
                } else {
                    FileRow(node: node)
                        .contentShape(Rectangle())
                        .onTapGesture { workspace.open(node) }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.documents.isEmpty {
                TabStrip(workspace: workspace)
                Divider()
            }

            if let document = workspace.selectedDocument {
                FileEditor(document: document)
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SourceEditorView(
            text: Binding(get: { document.text }, set: { document.text = $0 }),
            language: document.language,
            isDark: colorScheme == .dark
        )
    }
}
