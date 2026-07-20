import AppKit
import CodeEditLanguages
import Foundation

struct FileItem {
    let url: URL
    var name: String { url.lastPathComponent }
}

typealias FileNode = TreeNode<String, FileItem>

extension TreeNode where ID == String, Value == FileItem {
    var url: URL { value.url }
    var name: String { value.name }
    var isDirectory: Bool { isBranch }
}

final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let treeNodeID: String?
    let language: CodeLanguage
    @Published var text: String
    private(set) var savedText: String

    init(url: URL, text: String, treeNodeID: String? = nil) {
        self.url = url
        self.treeNodeID = treeNodeID
        self.text = text
        self.savedText = text
        self.language = CodeLanguage.detectLanguageFrom(
            url: url,
            prefixBuffer: String(text.prefix(256)),
            suffixBuffer: String(text.suffix(256))
        )
    }

    var isDirty: Bool { text != savedText }

    func markSaved() {
        savedText = text
        objectWillChange.send()
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    private struct EditorSession {
        var documents: [EditorDocument]
        var selectedDocumentID: UUID?
    }

    @Published private(set) var rootURL: URL?
    let fileTree = TreeModel<String, FileItem>()
    @Published private(set) var documents: [EditorDocument] = []
    @Published var selectedDocumentID: UUID?
    @Published var errorMessage: String?
    private var editorSessions: [URL: EditorSession] = [:]

    var selectedDocument: EditorDocument? {
        documents.first { $0.id == selectedDocumentID }
    }

    var selectedFileNodeID: String? { selectedDocument?.treeNodeID }

    init(arguments: [String] = CommandLine.arguments) {
        openCommandLineWorkspace(arguments)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Open Folder"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            openWorkspace(url)
        }
    }

    func openWorkspace(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()

        if rootURL == url {
            reloadFileTree(at: url)
            revealSelectedDocument()
            return
        }

        preserveCurrentEditorSession()
        rootURL = url
        if let session = editorSessions[url] {
            documents = session.documents
            selectedDocumentID = session.selectedDocumentID
        } else {
            documents = []
            selectedDocumentID = nil
        }
        reloadFileTree(at: url)
        revealSelectedDocument()
    }

    func open(_ node: FileNode) {
        guard !node.isDirectory else { return }
        openFile(node.url, treeNodeID: node.id)
    }

    func openFile(_ url: URL) {
        openFile(url, treeNodeID: fileNodeID(for: url))
    }

    private func openFile(_ url: URL, treeNodeID: String?) {
        let url = url.standardizedFileURL
        if let document = documents.first(where: {
            treeNodeID != nil ? $0.treeNodeID == treeNodeID : $0.url == url
        }) {
            activate(document)
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let document = EditorDocument(url: url, text: text, treeNodeID: treeNodeID)
            documents.append(document)
            activate(document)
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func select(_ document: EditorDocument) {
        activate(document)
    }

    func close(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        if selectedDocumentID == document.id {
            selectedDocumentID = documents.indices.contains(index)
                ? documents[index].id
                : documents.last?.id
            if let selectedDocument {
                if let treeNodeID = selectedDocument.treeNodeID {
                    fileTree.reveal(treeNodeID)
                }
            }
        }
    }

    func saveSelected() {
        guard let document = selectedDocument else { return }
        do {
            try document.text.write(to: document.url, atomically: true, encoding: .utf8)
            document.markSaved()
        } catch {
            errorMessage = "Could not save \(document.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func activate(_ document: EditorDocument) {
        selectedDocumentID = document.id
        if let treeNodeID = document.treeNodeID {
            fileTree.reveal(treeNodeID)
        }
    }

    private func preserveCurrentEditorSession() {
        guard let rootURL else { return }
        editorSessions[rootURL] = EditorSession(
            documents: documents,
            selectedDocumentID: selectedDocumentID
        )
    }

    private func reloadFileTree(at url: URL) {
        fileTree.replaceRoots(loadChildren(of: url, relativePath: ""))
    }

    private func revealSelectedDocument() {
        if let treeNodeID = selectedDocument?.treeNodeID {
            fileTree.reveal(treeNodeID)
        }
    }

    private func loadChildren(of directory: URL, relativePath: String) -> [FileNode] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let ignored = Set([".git", ".build", "DerivedData", ".DS_Store"])
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return [] }

        return urls.compactMap { url in
            guard !ignored.contains(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { return nil }
            let nodeID = relativePath.isEmpty
                ? url.lastPathComponent
                : relativePath + "/" + url.lastPathComponent
            if values.isDirectory == true {
                return FileNode(
                    id: nodeID,
                    value: FileItem(url: url),
                    children: loadChildren(of: url, relativePath: nodeID)
                )
            }
            return values.isRegularFile == true
                ? FileNode(id: nodeID, value: FileItem(url: url), children: nil)
                : nil
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func fileNodeID(for url: URL) -> String? {
        guard let rootURL else { return nil }
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents),
              fileComponents.count > rootComponents.count else { return nil }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func openCommandLineWorkspace(_ arguments: [String]) {
        guard let workspaceIndex = arguments.firstIndex(of: "--workspace"),
              arguments.indices.contains(workspaceIndex + 1) else { return }
        let root = URL(fileURLWithPath: arguments[workspaceIndex + 1], isDirectory: true)
        openWorkspace(root)

        guard let openIndex = arguments.firstIndex(of: "--open") else { return }
        for path in arguments.dropFirst(openIndex + 1).prefix(while: { !$0.hasPrefix("--") }) {
            openFile(root.appendingPathComponent(path))
        }
    }
}
