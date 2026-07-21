import Foundation

public enum GitQueryError: LocalizedError {
    case commandFailed(arguments: [String], message: String)
    case invalidOutput(String)
    case noParent(String)
    case blobNotFound(path: String, revision: String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(arguments, message):
            "git \(arguments.joined(separator: " ")) failed: \(message)"
        case let .invalidOutput(message):
            "Invalid Git output: \(message)"
        case let .noParent(message):
            message
        case let .blobNotFound(path, revision):
            "Could not load '\(path)' at \(revision)."
        }
    }
}

/// Git-backed change provider. Results are cached briefly per worktree and mode.
public actor GitQueryService: GitQuerying {
    private struct CacheKey: Hashable {
        let repositoryPath: String
        let mode: FileExplorerFilterMode
    }

    private struct CacheEntry {
        let snapshot: GitChangeSnapshot
        let expiresAt: Date
    }

    private let cacheTTL: TimeInterval
    private var cache: [CacheKey: CacheEntry] = [:]
    private var cacheGenerations: [CacheKey: UInt64] = [:]

    public init(cacheTTL: TimeInterval = 1.0) {
        self.cacheTTL = cacheTTL
    }

    public func changes(
        in repositoryURL: URL,
        mode: FileExplorerFilterMode,
        forceRefresh: Bool = false
    ) async throws -> GitChangeSnapshot {
        let repositoryURL = repositoryURL.standardizedFileURL
        let key = CacheKey(repositoryPath: repositoryURL.path, mode: mode)
        if !forceRefresh,
           let cached = cache[key],
           cached.expiresAt > Date() {
            return cached.snapshot
        }

        let generation = (cacheGenerations[key] ?? 0) &+ 1
        cacheGenerations[key] = generation
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try Self.loadChanges(in: repositoryURL, mode: mode)
        }.value
        if cacheGenerations[key] == generation {
            cache[key] = CacheEntry(
                snapshot: snapshot,
                expiresAt: Date().addingTimeInterval(cacheTTL)
            )
        }
        return snapshot
    }

    public func diff(_ request: GitDiffRequest) async throws -> GitDiffResult {
        try await Task.detached(priority: .userInitiated) {
            let comparison = try Self.diffComparison(for: request)
            guard let arguments = comparison.arguments else {
                return GitDiffResult(
                    contextID: request.contextID,
                    newPath: request.filePath,
                    hunks: [],
                    markers: [],
                    parentState: comparison.parentState
                )
            }
            let data: Data
            if let liveText = request.liveText,
               request.historicalCommit == nil,
               request.mode == .uncommitted || request.mode == .full {
                data = try Self.liveTextDiff(
                    liveText,
                    base: comparison.liveTextBase,
                    path: request.filePath,
                    repositoryURL: request.repositoryURL
                )
            } else {
                data = try Self.runGit(arguments, in: request.repositoryURL)
            }
            return GitDiffParser.parse(
                data,
                contextID: request.contextID,
                fallbackPath: request.filePath,
                parentState: comparison.parentState
            )
        }.value
    }

    public func fileContent(
        in repositoryURL: URL,
        path: String,
        mode: FileExplorerFilterMode
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let revision: String
            switch mode {
            case .uncommitted, .staged:
                guard Self.referenceExists("HEAD", in: repositoryURL) else {
                    throw GitQueryError.noParent("HEAD does not exist yet.")
                }
                revision = "HEAD"
            case .head, .full:
                let state = try Self.parentState(in: repositoryURL)
                guard case let .resolved(_, mergeBase) = state else {
                    if case let .noParent(message) = state {
                        throw GitQueryError.noParent(message)
                    }
                    throw GitQueryError.noParent("No parent branch is available for this branch.")
                }
                revision = mergeBase
            }

            do {
                return try Self.runGit(["show", "\(revision):\(path)"], in: repositoryURL)
            } catch {
                throw GitQueryError.blobNotFound(path: path, revision: revision)
            }
        }.value
    }

    private static func loadChanges(
        in repositoryURL: URL,
        mode: FileExplorerFilterMode
    ) throws -> GitChangeSnapshot {
        let parent: GitParentState?
        let diffArguments: [[String]]
        let includeUntracked: Bool

        switch mode {
        case .uncommitted:
            parent = nil
            diffArguments = referenceExists("HEAD", in: repositoryURL)
                ? [["diff", "HEAD", "--"]]
                : [["diff", "--cached", "--"], ["diff", "--"]]
            includeUntracked = true
        case .staged:
            parent = nil
            diffArguments = referenceExists("HEAD", in: repositoryURL)
                ? [["diff", "--cached", "HEAD", "--"]]
                : [["diff", "--cached", "--"]]
            includeUntracked = false
        case .head, .full:
            let resolved = try parentState(in: repositoryURL)
            parent = resolved
            if case let .resolved(_, mergeBase) = resolved {
                diffArguments = [mode == .head
                    ? ["diff", "\(mergeBase)..HEAD", "--"]
                    : ["diff", mergeBase, "--"]]
            } else {
                diffArguments = []
            }
            includeUntracked = mode == .full
        }

        var changes: [String: GitFileChange] = [:]
        for arguments in diffArguments {
            let status = try runGit(
                [arguments[0], "--name-status", "-z", "--find-renames", "--find-copies"]
                    + Array(arguments.dropFirst()),
                in: repositoryURL
            )
            let counts = try runGit(
                [arguments[0], "--numstat", "-z", "--find-renames", "--find-copies"]
                    + Array(arguments.dropFirst()),
                in: repositoryURL
            )
            let statusChanges = parseNameStatus(status)
            let parsedCounts = parseNumstat(counts)
            for (path, statusChange) in statusChanges {
                let count = parsedCounts[path]
                let parsed = GitFileChange(
                    path: statusChange.path,
                    oldPath: statusChange.oldPath ?? count?.oldPath,
                    kind: statusChange.kind,
                    additions: count?.additions,
                    deletions: count?.deletions,
                    isBinary: count?.isBinary ?? false
                )
                if changes[path]?.kind != .added {
                    changes[path] = parsed
                }
            }
            for (path, count) in parsedCounts where changes[path] != nil {
                guard let existing = changes[path], existing.additions == nil else { continue }
                changes[path] = GitFileChange(
                    path: existing.path,
                    oldPath: existing.oldPath ?? count.oldPath,
                    kind: existing.kind,
                    additions: count.additions,
                    deletions: count.deletions,
                    isBinary: count.isBinary
                )
            }
        }

        if includeUntracked {
            let output = try runGit(
                ["ls-files", "--others", "--exclude-standard", "-z", "--"],
                in: repositoryURL
            )
            for path in nulFields(output) where !path.isEmpty {
                changes[path] = GitFileChange(path: path, kind: .untracked)
            }
        }

        return GitChangeSnapshot(
            repositoryURL: repositoryURL,
            mode: mode,
            changes: changes.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            parentState: parent
        )
    }

    private static func parentState(
        in repositoryURL: URL,
        preferred: String? = nil,
        mirror: String? = nil
    ) throws -> GitParentState {
        var candidates: [String] = []
        if let preferred, !preferred.isEmpty { candidates.append(preferred) }

        // `mirror` remains in the request model for future compatibility. There
        // is no mirror parent provider in the current product.
        _ = mirror

        if let remoteHead = try? runGit(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            in: repositoryURL
        ).string.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteHead.isEmpty {
            candidates.append(remoteHead)
        }

        candidates += ["origin/main", "origin/master"]
        if let remotes = try? runGit(["remote"], in: repositoryURL).string {
            for remote in remotes.split(whereSeparator: \.isWhitespace).map(String.init) where remote != "origin" {
                candidates.append("\(remote)/main")
                candidates.append("\(remote)/master")
            }
        }
        candidates += ["main", "master"]

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            guard referenceExists(candidate, in: repositoryURL) else { continue }
            guard let base = try? runGit(["merge-base", candidate, "HEAD"], in: repositoryURL)
                .string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !base.isEmpty else { continue }
            return .resolved(reference: candidate, mergeBase: base)
        }
        return .noParent(message: "No parent branch is available for this branch.")
    }

    private static func referenceExists(_ reference: String, in repositoryURL: URL) -> Bool {
        (try? runGit(["rev-parse", "--verify", "--quiet", "\(reference)^{commit}"], in: repositoryURL)) != nil
    }

    private struct DiffComparison {
        let arguments: [String]?
        let liveTextBase: String?
        let parentState: GitParentState?
    }

    private static func diffComparison(for request: GitDiffRequest) throws -> DiffComparison {
        let common = ["--no-ext-diff", "--no-color", "--find-renames", "--find-copies", "--unified=3"]
        let path = ["--", request.filePath]
        if let commit = request.historicalCommit {
            guard let parent = try? runGit(
                ["rev-parse", "--verify", "\(commit)^1"],
                in: request.repositoryURL
            ).string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !parent.isEmpty else {
                return DiffComparison(
                    arguments: nil,
                    liveTextBase: nil,
                    parentState: .noParent(message: "This commit has no parent.")
                )
            }
            return DiffComparison(
                arguments: ["diff"] + common + [parent, commit] + path,
                liveTextBase: nil,
                parentState: .resolved(reference: "\(commit)^1", mergeBase: parent)
            )
        }

        switch request.mode {
        case .staged:
            return DiffComparison(
                arguments: ["diff"] + common + ["--cached", "HEAD"] + path,
                liveTextBase: nil,
                parentState: nil
            )
        case .uncommitted:
            return DiffComparison(
                arguments: ["diff"] + common + ["HEAD"] + path,
                liveTextBase: "HEAD",
                parentState: nil
            )
        case .head, .full:
            let parent = try parentState(
                in: request.repositoryURL,
                preferred: request.selectedParent,
                mirror: request.mirrorParent
            )
            guard case let .resolved(_, mergeBase) = parent else {
                return DiffComparison(arguments: nil, liveTextBase: nil, parentState: parent)
            }
            return DiffComparison(
                arguments: request.mode == .head
                    ? ["diff"] + common + ["\(mergeBase)..HEAD"] + path
                    : ["diff"] + common + [mergeBase] + path,
                liveTextBase: request.mode == .full ? mergeBase : nil,
                parentState: parent
            )
        }
    }

    private static func liveTextDiff(
        _ liveText: String,
        base: String?,
        path: String,
        repositoryURL: URL
    ) throws -> Data {
        guard let base else { return Data() }
        let baseData = (try? runGit(["show", "\(base):\(path)"], in: repositoryURL)) ?? Data()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevHQGitDiff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("old")
        let newURL = directory.appendingPathComponent("new")
        try baseData.write(to: oldURL)
        try Data(liveText.utf8).write(to: newURL)

        let raw = try runGit(
            ["diff", "--no-index", "--no-prefix", "--no-color", "--unified=3", "--", oldURL.path, newURL.path],
            in: repositoryURL,
            allowedExitStatuses: [0, 1]
        )
        var text = raw.string
        text = text.replacingOccurrences(of: oldURL.path, with: "a/\(path)")
        text = text.replacingOccurrences(of: newURL.path, with: "b/\(path)")
        return Data(text.utf8)
    }

    private struct Count {
        let oldPath: String?
        let additions: Int?
        let deletions: Int?
        let isBinary: Bool
    }

    private static func parseNameStatus(_ data: Data) -> [String: GitFileChange] {
        let fields = nulFields(data)
        var index = 0
        var result: [String: GitFileChange] = [:]
        while index < fields.count {
            let status = fields[index]
            index += 1
            guard !status.isEmpty, index < fields.count else { break }
            let code = status.first.map(String.init) ?? ""
            if code == "R" || code == "C" {
                guard index + 1 < fields.count else { break }
                let oldPath = fields[index]
                let newPath = fields[index + 1]
                index += 2
                result[newPath] = GitFileChange(
                    path: newPath,
                    oldPath: oldPath,
                    kind: code == "R" ? .renamed : .copied
                )
            } else {
                let path = fields[index]
                index += 1
                result[path] = GitFileChange(path: path, kind: changeKind(for: code))
            }
        }
        return result
    }

    private static func parseNumstat(_ data: Data) -> [String: Count] {
        let fields = nulFields(data)
        var index = 0
        var result: [String: Count] = [:]
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard !field.isEmpty else { continue }
            let columns = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 3 else { continue }
            let isBinary = columns[0] == "-" || columns[1] == "-"
            let additions = isBinary ? nil : Int(columns[0])
            let deletions = isBinary ? nil : Int(columns[1])
            if columns[2].isEmpty, index + 1 < fields.count {
                let oldPath = fields[index]
                let newPath = fields[index + 1]
                index += 2
                result[newPath] = Count(
                    oldPath: oldPath,
                    additions: additions,
                    deletions: deletions,
                    isBinary: isBinary
                )
            } else {
                result[columns[2]] = Count(
                    oldPath: nil,
                    additions: additions,
                    deletions: deletions,
                    isBinary: isBinary
                )
            }
        }
        return result
    }

    private static func changeKind(for status: String) -> GitChangeKind {
        switch status {
        case "A": .added
        case "M": .modified
        case "D": .deleted
        case "T": .typeChanged
        case "U": .conflicted
        default: .unknown
        }
    }

    private static func nulFields(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    private static func runGit(
        _ arguments: [String],
        in repositoryURL: URL,
        allowedExitStatuses: Set<Int32> = [0]
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryURL.path] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw GitQueryError.commandFailed(arguments: arguments, message: error.localizedDescription)
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard allowedExitStatuses.contains(process.terminationStatus) else {
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitQueryError.commandFailed(arguments: arguments, message: message)
        }
        return output
    }
}

public typealias GitService = GitQueryService

private extension Data {
    var string: String { String(decoding: self, as: UTF8.self) }
}
