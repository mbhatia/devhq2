import Foundation

public enum FileExplorerFilterMode: String, CaseIterable, Codable, Sendable {
    case full
    case uncommitted
    case staged
    case head

    public var label: String {
        switch self {
        case .full: "Full"
        case .uncommitted: "Uncommitted"
        case .staged: "Staged"
        case .head: "HEAD"
        }
    }

    public var iconName: String {
        switch self {
        case .full: "arrow.triangle.branch"
        case .uncommitted: "arrow.triangle.2.circlepath"
        case .staged: "checkmark.circle"
        case .head: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    public var tooltip: String { label }
}

public enum GitChangeKind: String, Codable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case untracked
    case typeChanged
    case conflicted
    case unknown

    public var label: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .untracked: "Untracked"
        case .typeChanged: "Type Changed"
        case .conflicted: "Conflicted"
        case .unknown: "Changed"
        }
    }

    public var status: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "?"
        case .typeChanged: "T"
        case .conflicted: "U"
        case .unknown: "•"
        }
    }
}

public struct GitFileChange: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let oldPath: String?
    public let kind: GitChangeKind
    public let additions: Int?
    public let deletions: Int?
    public let isBinary: Bool

    public init(
        path: String,
        oldPath: String? = nil,
        kind: GitChangeKind,
        additions: Int? = nil,
        deletions: Int? = nil,
        isBinary: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
    }
}

public enum GitParentState: Hashable, Codable, Sendable {
    case resolved(reference: String, mergeBase: String)
    case noParent(message: String)

    public var mergeBase: String? {
        guard case let .resolved(_, mergeBase) = self else { return nil }
        return mergeBase
    }
}

public struct GitChangeSnapshot: Hashable, Codable, Sendable {
    public let repositoryURL: URL
    public let mode: FileExplorerFilterMode
    public let changes: [GitFileChange]
    public let parentState: GitParentState?
    public let generatedAt: Date
    public let contextID: String

    public init(
        repositoryURL: URL,
        mode: FileExplorerFilterMode,
        changes: [GitFileChange],
        parentState: GitParentState? = nil,
        generatedAt: Date = Date(),
        contextID: String = UUID().uuidString
    ) {
        self.repositoryURL = repositoryURL
        self.mode = mode
        self.changes = changes
        self.parentState = parentState
        self.generatedAt = generatedAt
        self.contextID = contextID
    }
}

public struct GitDiffRequest: Hashable, Sendable {
    public let repositoryURL: URL
    public let filePath: String
    public let mode: FileExplorerFilterMode
    public let liveText: String?
    public let selectedParent: String?
    public let mirrorParent: String?
    public let historicalCommit: String?
    public let contextID: String

    public init(
        repositoryURL: URL,
        filePath: String,
        mode: FileExplorerFilterMode,
        liveText: String? = nil,
        selectedParent: String? = nil,
        mirrorParent: String? = nil,
        historicalCommit: String? = nil,
        contextID: String = UUID().uuidString
    ) {
        self.repositoryURL = repositoryURL
        self.filePath = filePath
        self.mode = mode
        self.liveText = liveText
        self.selectedParent = selectedParent
        self.mirrorParent = mirrorParent
        self.historicalCommit = historicalCommit
        self.contextID = contextID
    }
}

public enum GitDiffLineKind: String, Codable, Sendable {
    case context
    case addition
    case deletion
    case metadata
}

public struct GitDiffLine: Hashable, Codable, Sendable {
    public let kind: GitDiffLineKind
    public let text: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?

    public init(kind: GitDiffLineKind, text: String, oldLineNumber: Int? = nil, newLineNumber: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

public struct GitDiffHunk: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let header: String
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [GitDiffLine]

    public init(
        id: String = UUID().uuidString,
        header: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [GitDiffLine]
    ) {
        self.id = id
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public enum GitDiffMarkerKind: String, Codable, Sendable {
    case added
    case modified
    case deleted
}

public struct GitDiffMarker: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let line: Int
    public let kind: GitDiffMarkerKind
    public let hunkID: String

    public init(id: String = UUID().uuidString, line: Int, kind: GitDiffMarkerKind, hunkID: String) {
        self.id = id
        self.line = line
        self.kind = kind
        self.hunkID = hunkID
    }
}

public struct GitDiffResult: Hashable, Codable, Sendable {
    public let contextID: String
    public let oldPath: String?
    public let newPath: String
    public let hunks: [GitDiffHunk]
    public let markers: [GitDiffMarker]
    public let parentState: GitParentState?
    public let isBinary: Bool

    public init(
        contextID: String,
        oldPath: String? = nil,
        newPath: String,
        hunks: [GitDiffHunk],
        markers: [GitDiffMarker],
        parentState: GitParentState? = nil,
        isBinary: Bool = false
    ) {
        self.contextID = contextID
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
        self.markers = markers
        self.parentState = parentState
        self.isBinary = isBinary
    }

    public func belongs(to request: GitDiffRequest) -> Bool { contextID == request.contextID }
}

public protocol GitQuerying: Sendable {
    func changes(
        in repositoryURL: URL,
        mode: FileExplorerFilterMode,
        forceRefresh: Bool
    ) async throws -> GitChangeSnapshot

    func diff(_ request: GitDiffRequest) async throws -> GitDiffResult

    func fileContent(
        in repositoryURL: URL,
        path: String,
        mode: FileExplorerFilterMode
    ) async throws -> Data
}

public extension GitQuerying {
    func fileContent(
        in repositoryURL: URL,
        path: String,
        mode: FileExplorerFilterMode
    ) async throws -> Data {
        throw CocoaError(.fileReadUnsupportedScheme)
    }
}
