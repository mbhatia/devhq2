import Foundation

/// The complete identity of an editor diff request.
///
/// Keeping the live editor contents in this value ensures an unsaved edit starts
/// a new request and prevents an older result from being shown for newer text.
struct DiffEditorContext: Hashable, Sendable {
    let projectURL: URL
    let fileURL: URL
    let filterIdentity: String
    let currentText: String
    let comparisonRevision: String?
    let historicalContext: HistoricalContext?

    init(
        projectURL: URL,
        fileURL: URL,
        filterIdentity: String,
        currentText: String,
        comparisonRevision: String? = nil,
        historicalContext: HistoricalContext? = nil
    ) {
        self.projectURL = projectURL
        self.fileURL = fileURL
        self.filterIdentity = filterIdentity
        self.currentText = currentText
        self.comparisonRevision = comparisonRevision
        self.historicalContext = historicalContext
    }

    struct HistoricalContext: Hashable, Sendable {
        let commitID: String
        let parentCommitID: String?
        let oldPath: String?
        let newPath: String
    }
}

struct DiffEditorConfiguration {
    typealias Loader = @Sendable (DiffEditorContext) async throws -> DiffEditorSnapshot

    let isEnabled: Bool
    let context: DiffEditorContext
    let load: Loader

    init(isEnabled: Bool, context: DiffEditorContext, load: @escaping Loader) {
        self.isEnabled = isEnabled
        self.context = context
        self.load = load
    }

    /// Adapts the Git backend to the editor-local presentation contract.
    init(
        isEnabled: Bool,
        context: DiffEditorContext,
        mode: FileExplorerFilterMode,
        selectedParent: String? = nil,
        mirrorParent: String? = nil,
        includeLiveText: Bool = true,
        git: any GitQuerying
    ) {
        self.isEnabled = isEnabled
        self.context = context
        self.load = { context in
            let rootPath = context.projectURL.standardizedFileURL.path
            let filePath = context.fileURL.standardizedFileURL.path
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard filePath.hasPrefix(rootPrefix) else {
                throw DiffEditorLoadingError.fileOutsideProject
            }

            let request = GitDiffRequest(
                repositoryURL: context.projectURL,
                filePath: String(filePath.dropFirst(rootPrefix.count)),
                mode: mode,
                liveText: includeLiveText ? context.currentText : nil,
                selectedParent: selectedParent,
                mirrorParent: mirrorParent,
                historicalCommit: context.historicalContext?.commitID,
                contextID: UUID().uuidString
            )
            let result = try await git.diff(request)
            guard result.belongs(to: request) else {
                throw DiffEditorLoadingError.mismatchedResult
            }
            return DiffEditorSnapshot(result)
        }
    }
}

enum DiffEditorLoadingError: LocalizedError {
    case fileOutsideProject
    case mismatchedResult

    var errorDescription: String? {
        switch self {
        case .fileOutsideProject:
            "The file is outside the selected project."
        case .mismatchedResult:
            "The diff result belongs to an obsolete request."
        }
    }
}

struct DiffEditorSnapshot: Equatable, Sendable {
    var markers: [DiffEditorMarker]
    var hunks: [DiffEditorHunk]
    var statusMessage: String?

    init(
        markers: [DiffEditorMarker] = [],
        hunks: [DiffEditorHunk] = [],
        statusMessage: String? = nil
    ) {
        self.markers = markers
        self.hunks = hunks
        self.statusMessage = statusMessage
    }

    init(_ result: GitDiffResult) {
        markers = result.markers.map { marker in
            DiffEditorMarker(
                line: marker.line,
                kind: DiffEditorMarker.Kind(marker.kind),
                hunkID: marker.hunkID
            )
        }

        let fileMetadata: [String]
        if let oldPath = result.oldPath, oldPath != result.newPath {
            fileMetadata = ["--- \(oldPath)", "+++ \(result.newPath)"]
        } else {
            fileMetadata = ["--- \(result.newPath)", "+++ \(result.newPath)"]
        }
        hunks = result.hunks.map { hunk in
            DiffEditorHunk(
                id: hunk.id,
                metadata: fileMetadata,
                header: hunk.header,
                lines: hunk.lines.map { line in
                    DiffEditorHunk.Line(
                        kind: DiffEditorHunk.Line.Kind(line.kind),
                        text: line.text
                    )
                }
            )
        }

        if case .noParent(let message) = result.parentState {
            statusMessage = message
        } else if result.isBinary {
            statusMessage = "Binary diff is unavailable."
        } else {
            statusMessage = nil
        }
    }
}

struct DiffEditorMarker: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case added
        case modified
        case deleted
    }

    /// One-based editor line. Deletions use the nearest surviving line.
    let line: Int
    let kind: Kind
    let hunkID: String
}

struct DiffEditorHunk: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let metadata: [String]
    let header: String
    let lines: [Line]

    struct Line: Equatable, Hashable, Sendable {
        enum Kind: Equatable, Hashable, Sendable {
            case metadata
            case header
            case context
            case addition
            case deletion
        }

        let kind: Kind
        let text: String
    }
}

private extension DiffEditorMarker.Kind {
    init(_ kind: GitDiffMarkerKind) {
        switch kind {
        case .added: self = .added
        case .modified: self = .modified
        case .deleted: self = .deleted
        }
    }
}

private extension DiffEditorHunk.Line.Kind {
    init(_ kind: GitDiffLineKind) {
        switch kind {
        case .context: self = .context
        case .addition: self = .addition
        case .deletion: self = .deletion
        case .metadata: self = .metadata
        }
    }
}
