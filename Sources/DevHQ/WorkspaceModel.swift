import AppKit
import CodeEditLanguages
import Foundation

struct FileNode: Identifiable {
    let url: URL
    let children: [FileNode]?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var isDirectory: Bool { children != nil }
}

final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let language: CodeLanguage
    @Published var text: String
    private(set) var savedText: String

    init(url: URL, text: String) {
        self.url = url
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
    @Published private(set) var rootURL: URL?
    @Published private(set) var nodes: [FileNode] = []
    @Published private(set) var documents: [EditorDocument] = []
    @Published var selectedDocumentID: UUID?
    @Published var errorMessage: String?

    var selectedDocument: EditorDocument? {
        documents.first { $0.id == selectedDocumentID }
    }

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
        rootURL = url.standardizedFileURL
        documents = []
        selectedDocumentID = nil
        nodes = loadChildren(of: url)
    }

    func open(_ node: FileNode) {
        guard !node.isDirectory else { return }
        openFile(node.url)
    }

    func openFile(_ url: URL) {
        if let document = documents.first(where: { $0.url == url }) {
            selectedDocumentID = document.id
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let document = EditorDocument(url: url, text: text)
            documents.append(document)
            selectedDocumentID = document.id
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func select(_ document: EditorDocument) {
        selectedDocumentID = document.id
    }

    func close(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        if selectedDocumentID == document.id {
            selectedDocumentID = documents.indices.contains(index)
                ? documents[index].id
                : documents.last?.id
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

    private func loadChildren(of directory: URL) -> [FileNode] {
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
            if values.isDirectory == true {
                return FileNode(url: url, children: loadChildren(of: url))
            }
            return values.isRegularFile == true ? FileNode(url: url, children: nil) : nil
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
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
