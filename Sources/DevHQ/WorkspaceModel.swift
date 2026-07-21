import AppKit
import CodeEditLanguages
import Foundation

struct FileItem {
    let url: URL
    var name: String { url.lastPathComponent }
}

typealias FileNode = TreeNode<String, FileItem>

enum WorkspaceCommandOperationError: LocalizedError, Equatable {
    case noWorkspace
    case outsideWorkspace(URL)
    case targetExists(URL)
    case parentDirectoryMissing(URL)
    case invalidTerminalWorkingDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .noWorkspace:
            "Open a workspace before creating files or directories."
        case .outsideWorkspace(let url):
            "\(url.path) is outside the current workspace."
        case .targetExists(let url):
            "\(url.lastPathComponent) already exists."
        case .parentDirectoryMissing(let url):
            "The parent directory \(url.path) does not exist."
        case .invalidTerminalWorkingDirectory(let url):
            "Terminal working directory does not exist or is not a directory: \(url.path)"
        }
    }
}

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

    init(
        url: URL,
        text: String,
        savedText: String? = nil,
        treeNodeID: String? = nil
    ) {
        self.url = url
        self.treeNodeID = treeNodeID
        self.text = text
        self.savedText = savedText ?? text
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

enum EditorTab: Identifiable {
    case document(EditorDocument)
    case terminal(TerminalSession)

    var id: UUID {
        switch self {
        case .document(let document): document.id
        case .terminal(let terminal): terminal.id
        }
    }

    var document: EditorDocument? {
        guard case .document(let document) = self else { return nil }
        return document
    }

    var terminal: TerminalSession? {
        guard case .terminal(let terminal) = self else { return nil }
        return terminal
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    private struct EditorSession {
        var documents: [EditorDocument]
        var tabs: [EditorTab]
        var selectedDocumentID: UUID?
        var selectedTabID: UUID?
        var lastSelectedDocumentID: UUID?
        var expandedFileNodeIDs: Set<String>
    }

    private struct PersistentWorkspaceIdentity: Equatable {
        let canonicalRepositoryName: String
        let worktreeName: String
        let rootURL: URL
    }

    @Published private(set) var rootURL: URL?
    let fileTree = TreeModel<String, FileItem>()
    @Published private(set) var documents: [EditorDocument] = []
    @Published var selectedDocumentID: UUID?
    @Published private(set) var tabs: [EditorTab] = []
    @Published private(set) var selectedTabID: UUID?
    @Published var errorMessage: String?
    private var editorSessions: [URL: EditorSession] = [:]
    private let stateStore: WorkspaceStatePersisting?
    private var persistentWorkspaceIdentity: PersistentWorkspaceIdentity?
    private var lastSelectedDocumentID: UUID?

    var selectedDocument: EditorDocument? {
        documents.first { $0.id == selectedDocumentID }
    }

    var selectedTerminal: TerminalSession? {
        tabs.first { $0.id == selectedTabID }?.terminal
    }

    var terminalSessions: [TerminalSession] { tabs.compactMap(\.terminal) }

    var selectedFileNodeID: String? { selectedDocument?.treeNodeID }

    init(
        arguments: [String] = CommandLine.arguments,
        stateStore: WorkspaceStatePersisting? = nil
    ) {
        self.stateStore = stateStore
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
        saveCurrentWorkspaceState()
        persistentWorkspaceIdentity = nil
        openNonpersistentWorkspace(url)
    }

    func openWorktree(
        canonicalRepositoryName: String,
        worktreeName: String,
        url: URL
    ) {
        guard stateStore != nil else {
            openWorkspace(url)
            return
        }

        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let destination = PersistentWorkspaceIdentity(
            canonicalRepositoryName: canonicalRepositoryName,
            worktreeName: worktreeName,
            rootURL: url
        )

        if persistentWorkspaceIdentity == destination, rootURL == url {
            let expandedIDs = fileTree.expandedIDs
            reloadFileTree(at: url)
            fileTree.restoreExpandedIDs(expandedIDs)
            return
        }

        if persistentWorkspaceIdentity != nil {
            saveCurrentWorkspaceState()
        }
        preserveCurrentEditorSession()

        persistentWorkspaceIdentity = destination
        rootURL = url
        documents = []
        selectedDocumentID = nil
        tabs = []
        selectedTabID = nil
        lastSelectedDocumentID = nil
        reloadFileTree(at: url)
        if let session = editorSessions[url] {
            documents = session.documents
            tabs = session.tabs
            selectedDocumentID = session.selectedDocumentID
            selectedTabID = session.selectedTabID
            lastSelectedDocumentID = session.lastSelectedDocumentID
            fileTree.restoreExpandedIDs(session.expandedFileNodeIDs)
            updateTerminalActivity()
        } else {
            restoreWorkspaceState(for: destination)
        }
    }

    /// Reconciles a branch rename or checkout discovered for the active
    /// worktree without disturbing its current UI session.
    func updateCurrentWorktreeIdentity(
        canonicalRepositoryName: String,
        worktreeName: String,
        url: URL
    ) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let identity = persistentWorkspaceIdentity,
              identity.canonicalRepositoryName == canonicalRepositoryName,
              identity.rootURL == url,
              rootURL == url,
              identity.worktreeName != worktreeName else { return }

        persistentWorkspaceIdentity = PersistentWorkspaceIdentity(
            canonicalRepositoryName: canonicalRepositoryName,
            worktreeName: worktreeName,
            rootURL: url
        )
        saveCurrentWorkspaceState()
    }

    /// Synchronously persists the active worktree, if it was opened with
    /// `openWorktree(canonicalRepositoryName:worktreeName:url:)`.
    func saveCurrentWorkspaceState() {
        guard let stateStore,
              let identity = persistentWorkspaceIdentity,
              rootURL == identity.rootURL else { return }

        let persistedDocuments = documents.compactMap { document -> (String, PersistedEditorTabState)? in
            guard let path = relativePath(for: document.url, in: identity.rootURL) else {
                return nil
            }
            return (
                path,
                PersistedEditorTabState(
                    path: path,
                    unsavedText: document.isDirty ? document.text : nil,
                    savedText: document.isDirty ? document.savedText : nil
                )
            )
        }
        let persistedDocumentPaths = Set(persistedDocuments.map(\.0))
        let persistenceDocument = selectedDocument
            ?? documents.first { $0.id == lastSelectedDocumentID }
        let selectedTabPath = persistenceDocument
            .flatMap { relativePath(for: $0.url, in: identity.rootURL) }
            .flatMap { persistedDocumentPaths.contains($0) ? $0 : nil }
        let state = PersistedWorkspaceState(
            expandedFileNodeIDs: fileTree.expandedIDs.sorted(),
            tabs: persistedDocuments.map(\.1),
            selectedTabPath: selectedTabPath
        )

        do {
            try stateStore.saveWorkspaceState(
                state,
                canonicalRepositoryName: identity.canonicalRepositoryName,
                worktreeName: identity.worktreeName
            )
        } catch {
            errorMessage = "Could not save workspace state: \(error.localizedDescription)"
        }
    }

    private func openNonpersistentWorkspace(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()

        if rootURL == url {
            reloadFileTree(at: url)
            revealSelectedDocument()
            return
        }

        preserveCurrentEditorSession()
        rootURL = url
        var restoredExpandedFileNodeIDs: Set<String>?
        if let session = editorSessions[url] {
            documents = session.documents
            selectedDocumentID = session.selectedDocumentID
            tabs = session.tabs
            selectedTabID = session.selectedTabID
            lastSelectedDocumentID = session.lastSelectedDocumentID
            restoredExpandedFileNodeIDs = session.expandedFileNodeIDs
        } else {
            documents = []
            selectedDocumentID = nil
            tabs = []
            selectedTabID = nil
            lastSelectedDocumentID = nil
        }
        reloadFileTree(at: url)
        if let restoredExpandedFileNodeIDs {
            fileTree.restoreExpandedIDs(restoredExpandedFileNodeIDs)
        }
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
            tabs.append(.document(document))
            activate(document)
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func select(_ document: EditorDocument) {
        activate(document)
    }

    func select(_ terminal: TerminalSession) {
        activateTab(id: terminal.id)
    }

    @discardableResult
    func newTerminal(
        workingDirectory: URL? = nil,
        command: [String]? = nil,
        shell: String? = nil
    ) throws -> TerminalSession {
        guard let rootURL else { throw WorkspaceCommandOperationError.noWorkspace }
        let workingDirectory = (workingDirectory ?? rootURL)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workingDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw WorkspaceCommandOperationError.invalidTerminalWorkingDirectory(workingDirectory)
        }

        let terminal = try TerminalSession(
            rootURL: rootURL,
            workingDirectory: workingDirectory,
            command: command,
            shell: shell
        )
        tabs.append(.terminal(terminal))
        activateTab(id: terminal.id)
        errorMessage = nil
        return terminal
    }

    func close(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        let tabIndex = tabs.firstIndex { $0.id == document.id }
        tabs.removeAll { $0.id == document.id }
        if lastSelectedDocumentID == document.id { lastSelectedDocumentID = documents.last?.id }
        if selectedDocumentID == document.id {
            selectAdjacentTab(afterRemoving: tabIndex)
        }
    }

    func close(_ terminal: TerminalSession) {
        guard let index = tabs.firstIndex(where: { $0.id == terminal.id }) else { return }
        terminal.close()
        tabs.remove(at: index)
        if selectedTabID == terminal.id { selectAdjacentTab(afterRemoving: index) }
    }

    /// Closes the active tab. Unsaved text is discarded, matching the existing
    /// tab close button behavior.
    func closeSelected() {
        if let selectedTerminal { close(selectedTerminal) }
        else if let selectedDocument { close(selectedDocument) }
    }

    @discardableResult
    func createFile(at url: URL) throws -> EditorDocument {
        do {
            let target = try validatedCreationTarget(url)
            try Data().write(to: target, options: .withoutOverwriting)
            refreshFileTreePreservingExpansion()
            openFile(target)
            errorMessage = nil
            guard let selectedDocument, selectedDocument.url == target else {
                throw CocoaError(.fileReadUnknown)
            }
            return selectedDocument
        } catch {
            errorMessage = "Could not create file: \(error.localizedDescription)"
            throw error
        }
    }

    func createDirectory(at url: URL) throws {
        do {
            let target = try validatedCreationTarget(url)
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories: false
            )
            refreshFileTreePreservingExpansion()
            errorMessage = nil
        } catch {
            errorMessage = "Could not create directory: \(error.localizedDescription)"
            throw error
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
        selectedTabID = document.id
        lastSelectedDocumentID = document.id
        updateTerminalActivity()
        if let treeNodeID = document.treeNodeID {
            fileTree.reveal(treeNodeID)
        }
    }

    private func preserveCurrentEditorSession() {
        guard let rootURL else { return }
        editorSessions[rootURL] = EditorSession(
            documents: documents,
            tabs: tabs,
            selectedDocumentID: selectedDocumentID,
            selectedTabID: selectedTabID,
            lastSelectedDocumentID: lastSelectedDocumentID,
            expandedFileNodeIDs: fileTree.expandedIDs
        )
    }

    private func restoreWorkspaceState(for identity: PersistentWorkspaceIdentity) {
        guard let stateStore else { return }

        let state: PersistedWorkspaceState?
        do {
            state = try stateStore.loadWorkspaceState(
                canonicalRepositoryName: identity.canonicalRepositoryName,
                worktreeName: identity.worktreeName
            )
        } catch {
            errorMessage = "Could not load workspace state: \(error.localizedDescription)"
            return
        }
        guard let state else { return }

        fileTree.restoreExpandedIDs(state.expandedFileNodeIDs)

        var restoredDocuments: [(path: String, document: EditorDocument)] = []
        var restoredPaths = Set<String>()
        for tab in state.tabs {
            guard !restoredPaths.contains(tab.path),
                  let url = validatedURL(forRelativePath: tab.path, in: identity.rootURL) else {
                continue
            }

            let document: EditorDocument
            switch (tab.unsavedText, tab.savedText) {
            case let (.some(text), .some(savedText)):
                document = EditorDocument(
                    url: url,
                    text: text,
                    savedText: savedText,
                    treeNodeID: tab.path
                )
            case (nil, nil):
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    continue
                }
                document = EditorDocument(url: url, text: text, treeNodeID: tab.path)
            default:
                continue
            }
            restoredPaths.insert(tab.path)
            restoredDocuments.append((tab.path, document))
        }

        documents = restoredDocuments.map(\.document)
        selectedDocumentID = state.selectedTabPath.flatMap { selectedPath in
            restoredDocuments.first { $0.path == selectedPath }?.document.id
        }
        tabs = documents.map(EditorTab.document)
        selectedTabID = selectedDocumentID
        lastSelectedDocumentID = selectedDocumentID
    }

    private func reloadFileTree(at url: URL) {
        fileTree.replaceRoots(loadChildren(of: url, relativePath: ""))
    }

    private func refreshFileTreePreservingExpansion() {
        guard let rootURL else { return }
        let expandedIDs = fileTree.expandedIDs
        reloadFileTree(at: rootURL)
        fileTree.restoreExpandedIDs(expandedIDs)
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
        return relativePath(for: url, in: rootURL)
    }

    private func relativePath(for url: URL, in rootURL: URL) -> String? {
        let rootComponents = rootURL.standardizedFileURL
            .resolvingSymlinksInPath().pathComponents
        let fileComponents = url.standardizedFileURL
            .resolvingSymlinksInPath().pathComponents
        guard fileComponents.starts(with: rootComponents),
              fileComponents.count > rootComponents.count else { return nil }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func validatedURL(forRelativePath path: String, in rootURL: URL) -> URL? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        let candidate = rootURL.appendingPathComponent(path).standardizedFileURL
        guard relativePath(for: candidate, in: rootURL) == path else { return nil }
        return candidate
    }

    private func validatedCreationTarget(_ url: URL) throws -> URL {
        guard let rootURL else { throw WorkspaceCommandOperationError.noWorkspace }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        guard relativePath(for: target, in: rootURL) != nil else {
            throw WorkspaceCommandOperationError.outsideWorkspace(target)
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw WorkspaceCommandOperationError.targetExists(target)
        }

        let parent = target.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceCommandOperationError.parentDirectoryMissing(parent)
        }
        return target
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

    func closeAllTerminals() {
        let activeTerminalID = selectedTerminal?.id
        for terminal in allTerminalSessions { terminal.close() }
        tabs.removeAll { $0.terminal != nil }
        for key in editorSessions.keys {
            guard var session = editorSessions[key] else { continue }
            let selectedWasTerminal = session.tabs.first {
                $0.id == session.selectedTabID
            }?.terminal != nil
            session.tabs.removeAll { $0.terminal != nil }
            if selectedWasTerminal {
                session.selectedTabID = session.lastSelectedDocumentID
                session.selectedDocumentID = session.lastSelectedDocumentID
            }
            editorSessions[key] = session
        }
        if activeTerminalID != nil { selectAdjacentTab(afterRemoving: nil) }
    }

    private var allTerminalSessions: [TerminalSession] {
        var seen = Set<UUID>()
        return (terminalSessions + editorSessions.values.flatMap { $0.tabs.compactMap(\.terminal) })
            .filter { seen.insert($0.id).inserted }
    }

    private func activateTab(id: UUID) {
        selectedTabID = id
        if let document = tabs.first(where: { $0.id == id })?.document {
            selectedDocumentID = document.id
            lastSelectedDocumentID = document.id
            if let treeNodeID = document.treeNodeID { fileTree.reveal(treeNodeID) }
        } else {
            selectedDocumentID = nil
        }
        updateTerminalActivity()
    }

    private func selectAdjacentTab(afterRemoving removedIndex: Int?) {
        guard !tabs.isEmpty else {
            selectedTabID = nil
            selectedDocumentID = nil
            updateTerminalActivity()
            return
        }
        let index = min(removedIndex ?? (tabs.count - 1), tabs.count - 1)
        activateTab(id: tabs[index].id)
    }

    private func updateTerminalActivity() {
        for terminal in allTerminalSessions { terminal.setActive(terminal.id == selectedTabID) }
    }
}
