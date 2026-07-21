import Foundation
import XCTest
@testable import DevHQ

final class WorkspaceFileFilterTests: XCTestCase {
    func testFilterMetadataHasFourNamedIconOnlyToolbarOptions() {
        XCTAssertEqual(FileExplorerFilterMode.allCases, [.full, .uncommitted, .staged, .head])
        XCTAssertEqual(FileExplorerFilterMode.allCases.map(\.label), [
            "Full", "Uncommitted", "Staged", "HEAD"
        ])
        XCTAssertTrue(FileExplorerFilterMode.allCases.allSatisfy { !$0.iconName.isEmpty })
        XCTAssertEqual(
            FileExplorerFilterMode.allCases.map(\.tooltip),
            FileExplorerFilterMode.allCases.map(\.label)
        )
    }

    @MainActor
    func testFullTreeRemainsOrdinaryAndFilteredTreeIncludesAncestorsAndDeletedFiles() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let changes = [
            GitFileChange(
                path: "Sources/Feature/Modified.swift",
                kind: .modified,
                additions: 3,
                deletions: 1
            ),
            GitFileChange(
                path: "Sources/Feature/Deleted.swift",
                kind: .deleted,
                additions: 0,
                deletions: 8
            )
        ]
        let query = WorkspaceFilterGitQuery(changes: changes)
        let model = WorkspaceModel(arguments: ["DevHQ"], gitQuery: query)

        model.openWorkspace(root)
        await waitForRefresh(model)

        XCTAssertNotNil(findNode("README.md", in: model.fileTree.roots))
        XCTAssertEqual(
            findNode("Sources/Feature/Modified.swift", in: model.fileTree.roots)?.value.change,
            changes[0]
        )
        model.fileTree.restoreExpandedIDs(["Sources", "Sources/Feature"])

        model.selectFileFilter(.uncommitted)
        XCTAssertTrue(model.isFileFilterRefreshing)
        await waitForRefresh(model)

        XCTAssertNil(findNode("README.md", in: model.fileTree.roots))
        XCTAssertNotNil(findNode("Sources", in: model.fileTree.roots))
        XCTAssertNotNil(findNode("Sources/Feature", in: model.fileTree.roots))
        XCTAssertEqual(
            findNode("Sources/Feature/Deleted.swift", in: model.fileTree.roots)?.value.change?.kind,
            .deleted
        )
        XCTAssertTrue(model.fileTree.expandedIDs.contains("Sources"))
        XCTAssertTrue(model.fileTree.expandedIDs.contains("Sources/Feature"))
        XCTAssertEqual(model.fileFilterChangeCount, 2)
        XCTAssertEqual(model.fileFilterStatusMessage, "2 changed files")

        let calls = await query.calls
        XCTAssertEqual(calls.map(\.mode), [.full, .uncommitted])
        XCTAssertEqual(calls.map(\.forceRefresh), [false, true])
    }

    @MainActor
    func testDeletedFileUsesReadOnlySnapshotAndKeepsPreviewPromotionRulesSafe() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let query = WorkspaceFilterGitQuery(changes: [
            GitFileChange(path: "Removed.swift", kind: .deleted),
            GitFileChange(path: "README.md", kind: .modified)
        ], fileContent: Data("uncommitted baseline".utf8))
        let model = WorkspaceModel(arguments: ["DevHQ"], gitQuery: query)
        model.openWorkspace(root)

        model.selectFileFilter(.uncommitted)
        await waitForRefresh(model)
        let deleted = try XCTUnwrap(findNode("Removed.swift", in: model.fileTree.roots))
        model.open(deleted)
        await waitForSelectedDocument(model, named: "Removed.swift")

        XCTAssertEqual(model.selectedDocument?.text, "uncommitted baseline")
        XCTAssertTrue(model.selectedDocument?.isReadOnly == true)
        XCTAssertTrue(model.selectedDocument?.isEphemeral == true)
        let deletedDocument = try XCTUnwrap(model.selectedDocument)
        let diffConfiguration = try XCTUnwrap(
            model.diffEditorConfiguration(for: deletedDocument)
        )
        let diffSnapshot = try await diffConfiguration.load(diffConfiguration.context)
        let diffRequest = await query.lastDiffRequest
        XCTAssertEqual(diffRequest?.mode, .uncommitted)
        XCTAssertNil(diffRequest?.liveText)
        XCTAssertEqual(diffSnapshot.markers.first?.kind, .deleted)
        model.saveSelected()
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.url.path))
        XCTAssertEqual(model.errorMessage, "Cannot save read-only snapshot Removed.swift.")

        let readme = try XCTUnwrap(findNode("README.md", in: model.fileTree.roots))
        model.open(readme)
        XCTAssertEqual(model.documents.map { $0.url.lastPathComponent }, ["README.md"])

        model.open(deleted)
        await waitForSelectedDocument(model, named: "Removed.swift")
        model.openPersistently(deleted)
        XCTAssertFalse(model.selectedDocument?.isEphemeral == true)
        model.open(readme)
        XCTAssertEqual(
            model.documents.map { $0.url.lastPathComponent },
            ["Removed.swift", "README.md"]
        )
        XCTAssertTrue(model.documents.first?.isReadOnly == true)

        let promotedDeleted = try XCTUnwrap(model.documents.first)
        await query.setFileContent(Data("full baseline".utf8), mode: .full)
        model.selectFileFilter(.full)
        await waitForRefresh(model)
        XCTAssertEqual(promotedDeleted.text, "uncommitted baseline")
        XCTAssertEqual(promotedDeleted.snapshotFilterMode, .uncommitted)

        model.select(promotedDeleted)
        await waitForSelectedText(model, text: "full baseline")
        XCTAssertEqual(model.selectedDocument?.snapshotFilterMode, .full)
        XCTAssertTrue(model.selectedDocument === promotedDeleted)

        try "restored disk file".write(
            to: deleted.url,
            atomically: true,
            encoding: .utf8
        )
        model.refreshFileFilter()
        await waitForRefresh(model)
        let restoredNode = try XCTUnwrap(findNode("Removed.swift", in: model.fileTree.roots))
        model.open(restoredNode)
        XCTAssertEqual(model.selectedDocument?.text, "restored disk file")
        XCTAssertFalse(model.selectedDocument?.isReadOnly == true)
        XCTAssertFalse(model.selectedDocument?.isEphemeral == true)
        XCTAssertFalse(model.selectedDocument === promotedDeleted)
    }

    @MainActor
    func testNoParentStateIsVisibleInFilterStatus() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let query = WorkspaceFilterGitQuery(
            changes: [],
            parentState: .noParent(message: "No parent branch is available.")
        )
        let model = WorkspaceModel(arguments: ["DevHQ"], gitQuery: query)
        model.openWorkspace(root)
        model.selectFileFilter(.head)
        await waitForRefresh(model)

        XCTAssertEqual(model.fileFilterStatusMessage, "No parent branch is available.")
        XCTAssertTrue(model.fileTree.roots.isEmpty)
    }

    @MainActor
    func testComparisonRevisionChangesForExplicitRefreshAndParentChange() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let query = WorkspaceFilterGitQuery(
            changes: [],
            parentState: .resolved(reference: "origin/main", mergeBase: "first-base")
        )
        let model = WorkspaceModel(arguments: ["DevHQ"], gitQuery: query)
        model.openWorkspace(root)
        model.selectFileFilter(.head)
        await waitForRefresh(model)
        let firstRevision = model.fileFilterComparisonRevision

        await query.setParentState(
            .resolved(reference: "origin/main", mergeBase: "second-base")
        )
        model.refreshFileFilter()
        let refreshingRevision = model.fileFilterComparisonRevision
        XCTAssertNotEqual(refreshingRevision, firstRevision)
        await waitForRefresh(model)

        XCTAssertNotEqual(model.fileFilterComparisonRevision, firstRevision)
        XCTAssertTrue(model.fileFilterComparisonRevision.contains("second-base"))
        model.openFile(root.appendingPathComponent("README.md"))
        let document = try XCTUnwrap(model.selectedDocument)
        XCTAssertEqual(
            model.diffEditorConfiguration(for: document)?.context.comparisonRevision,
            model.fileFilterComparisonRevision
        )
    }

    @MainActor
    func testLateModeAndProjectResultsCannotReplaceCurrentFilterState() async throws {
        let firstRoot = try makeWorkspace()
        let secondRoot = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let query = ControlledWorkspaceFilterGitQuery()
        let model = WorkspaceModel(arguments: ["DevHQ"], gitQuery: query)

        model.openWorkspace(firstRoot)
        await waitForPendingCalls(query, count: 1)
        model.selectFileFilter(.staged)
        await waitForPendingCalls(query, count: 2)
        model.openWorkspace(secondRoot)
        await waitForPendingCalls(query, count: 3)

        await query.complete(
            repositoryURL: secondRoot,
            mode: .staged,
            changes: [GitFileChange(path: "Current.swift", kind: .added)],
            contextID: "current-context"
        )
        await waitForRefresh(model)
        XCTAssertNotNil(findNode("Current.swift", in: model.fileTree.roots))
        XCTAssertEqual(model.fileFilterComparisonRevision, "current-context:staged:no-parent-context")

        await query.complete(
            repositoryURL: firstRoot,
            mode: .staged,
            changes: [GitFileChange(path: "OldMode.swift", kind: .modified)],
            contextID: "old-mode-context"
        )
        await query.complete(
            repositoryURL: firstRoot,
            mode: .full,
            changes: [GitFileChange(path: "OldProject.swift", kind: .modified)],
            contextID: "old-project-context"
        )
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(model.rootURL, secondRoot.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(model.fileFilterMode, .staged)
        XCTAssertNotNil(findNode("Current.swift", in: model.fileTree.roots))
        XCTAssertNil(findNode("OldMode.swift", in: model.fileTree.roots))
        XCTAssertNil(findNode("OldProject.swift", in: model.fileTree.roots))
        XCTAssertEqual(model.fileFilterComparisonRevision, "current-context:staged:no-parent-context")
    }

    @MainActor
    func testSlowDeletedFetchCannotStealSelectionFromExistingOrNormalFile() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let query = DelayedFileContentGitQuery(changes: [
            GitFileChange(path: "Removed.swift", kind: .deleted),
            GitFileChange(path: "README.md", kind: .modified)
        ])
        let model = WorkspaceModel(arguments: ["DevHQ"], gitQuery: query)
        model.openWorkspace(root)
        model.selectFileFilter(.uncommitted)
        await waitForRefresh(model)
        let deleted = try XCTUnwrap(findNode("Removed.swift", in: model.fileTree.roots))
        let readmeNode = try XCTUnwrap(findNode("README.md", in: model.fileTree.roots))
        model.openFile(readmeNode.url)
        let readme = try XCTUnwrap(model.selectedDocument)

        model.open(deleted)
        await waitForPendingContent(query, count: 1)
        model.select(readme)
        await query.completeNextContent(Data("late existing-tab result".utf8))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(model.selectedDocument === readme)
        XCTAssertNil(model.documents.first { $0.url.lastPathComponent == "Removed.swift" })

        model.open(deleted)
        await waitForPendingContent(query, count: 1)
        model.open(readmeNode)
        await query.completeNextContent(Data("late normal-file result".utf8))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(model.selectedDocument === readme)
        XCTAssertNil(model.documents.first { $0.url.lastPathComponent == "Removed.swift" })
    }

    @MainActor
    private func waitForRefresh(
        _ model: WorkspaceModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 where model.isFileFilterRefreshing {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(model.isFileFilterRefreshing, file: file, line: line)
    }

    private func waitForPendingCalls(
        _ query: ControlledWorkspaceFilterGitQuery,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await query.pendingCount == count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Expected \(count) pending Git queries", file: file, line: line)
    }

    private func waitForPendingContent(
        _ query: DelayedFileContentGitQuery,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await query.pendingContentCount == count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Expected \(count) pending content queries", file: file, line: line)
    }

    @MainActor
    private func waitForSelectedDocument(
        _ model: WorkspaceModel,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if model.selectedDocument?.url.lastPathComponent == name { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Expected selected document \(name)", file: file, line: line)
    }

    @MainActor
    private func waitForSelectedText(
        _ model: WorkspaceModel,
        text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if model.selectedDocument?.text == text { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Expected selected text \(text)", file: file, line: line)
    }

    private func findNode(_ id: String, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children, let match = findNode(id, in: children) {
                return match
            }
        }
        return nil
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let feature = root.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
        try "changed".write(
            to: feature.appendingPathComponent("Modified.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "readme".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }
}

private actor WorkspaceFilterGitQuery: GitQuerying {
    struct Call: Sendable {
        let mode: FileExplorerFilterMode
        let forceRefresh: Bool
    }

    let changesToReturn: [GitFileChange]
    private var parentState: GitParentState?
    private var fileContentByMode: [FileExplorerFilterMode: Data]
    private(set) var lastDiffRequest: GitDiffRequest?
    private(set) var calls: [Call] = []

    init(
        changes: [GitFileChange],
        parentState: GitParentState? = nil,
        fileContent: Data? = nil
    ) {
        self.changesToReturn = changes
        self.parentState = parentState
        self.fileContentByMode = fileContent.map { content in
            Dictionary(
                uniqueKeysWithValues: FileExplorerFilterMode.allCases.map { ($0, content) }
            )
        } ?? [:]
    }

    func setParentState(_ parentState: GitParentState?) {
        self.parentState = parentState
    }

    func setFileContent(_ content: Data, mode: FileExplorerFilterMode) {
        fileContentByMode[mode] = content
    }

    func changes(
        in repositoryURL: URL,
        mode: FileExplorerFilterMode,
        forceRefresh: Bool
    ) async throws -> GitChangeSnapshot {
        calls.append(Call(mode: mode, forceRefresh: forceRefresh))
        return GitChangeSnapshot(
            repositoryURL: repositoryURL,
            mode: mode,
            changes: changesToReturn,
            parentState: parentState
        )
    }

    func diff(_ request: GitDiffRequest) async throws -> GitDiffResult {
        lastDiffRequest = request
        return GitDiffResult(
            contextID: request.contextID,
            newPath: request.filePath,
            hunks: [],
            markers: [GitDiffMarker(line: 1, kind: .deleted, hunkID: "deleted")]
        )
    }

    func fileContent(
        in repositoryURL: URL,
        path: String,
        mode: FileExplorerFilterMode
    ) async throws -> Data {
        guard let content = fileContentByMode[mode] else {
            throw CocoaError(.featureUnsupported)
        }
        return content
    }
}

private actor ControlledWorkspaceFilterGitQuery: GitQuerying {
    private struct Pending {
        let repositoryURL: URL
        let mode: FileExplorerFilterMode
        let continuation: CheckedContinuation<GitChangeSnapshot, Error>
    }

    private var pending: [Pending] = []

    var pendingCount: Int { pending.count }

    func changes(
        in repositoryURL: URL,
        mode: FileExplorerFilterMode,
        forceRefresh: Bool
    ) async throws -> GitChangeSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(
                repositoryURL: repositoryURL,
                mode: mode,
                continuation: continuation
            ))
        }
    }

    func complete(
        repositoryURL: URL,
        mode: FileExplorerFilterMode,
        changes: [GitFileChange],
        contextID: String
    ) {
        let expectedURL = repositoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let index = pending.firstIndex(where: {
            $0.repositoryURL.standardizedFileURL.resolvingSymlinksInPath() == expectedURL
                && $0.mode == mode
        }) else { return }
        let call = pending.remove(at: index)
        call.continuation.resume(returning: GitChangeSnapshot(
            repositoryURL: expectedURL,
            mode: mode,
            changes: changes,
            contextID: contextID
        ))
    }

    func diff(_ request: GitDiffRequest) async throws -> GitDiffResult {
        throw CocoaError(.featureUnsupported)
    }

    func fileContent(
        in repositoryURL: URL,
        path: String,
        mode: FileExplorerFilterMode
    ) async throws -> Data {
        throw CocoaError(.featureUnsupported)
    }
}

private actor DelayedFileContentGitQuery: GitQuerying {
    private let changesToReturn: [GitFileChange]
    private var pendingContent: [CheckedContinuation<Data, Error>] = []

    init(changes: [GitFileChange]) {
        changesToReturn = changes
    }

    var pendingContentCount: Int { pendingContent.count }

    func changes(
        in repositoryURL: URL,
        mode: FileExplorerFilterMode,
        forceRefresh: Bool
    ) async throws -> GitChangeSnapshot {
        GitChangeSnapshot(
            repositoryURL: repositoryURL,
            mode: mode,
            changes: changesToReturn
        )
    }

    func fileContent(
        in repositoryURL: URL,
        path: String,
        mode: FileExplorerFilterMode
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            pendingContent.append(continuation)
        }
    }

    func completeNextContent(_ data: Data) {
        guard !pendingContent.isEmpty else { return }
        pendingContent.removeFirst().resume(returning: data)
    }

    func diff(_ request: GitDiffRequest) async throws -> GitDiffResult {
        throw CocoaError(.featureUnsupported)
    }
}
