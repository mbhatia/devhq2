import Foundation

struct SSHRemoteRepositorySource: Codable, Hashable, Sendable {
    let server: String
    let remotePath: String

    init(server: String, remotePath: String) throws {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let remotePath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty,
              !server.contains(":"),
              !server.hasPrefix("-"),
              server.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !server.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !remotePath.isEmpty,
              !remotePath.unicodeScalars.contains(where: CharacterSet.newlines.contains),
              !remotePath.utf8.contains(0)
        else {
            throw SSHRemoteRepositoryError.invalidSource
        }
        self.server = server
        self.remotePath = remotePath
    }

    init(specification: String) throws {
        guard let separator = specification.firstIndex(of: ":") else {
            throw SSHRemoteRepositoryError.invalidSource
        }
        try self.init(
            server: String(specification[..<separator]),
            remotePath: String(specification[specification.index(after: separator)...])
        )
    }

    var specification: String { "\(server):\(remotePath)" }

    var repositoryName: String {
        let name = URL(fileURLWithPath: remotePath).lastPathComponent
        return name.isEmpty ? "repo" : name
    }
}

struct SSHRemoteWorktreeSnapshot: Codable, Hashable, Sendable {
    let name: String
    let localURL: URL
    let remotePath: String
    let isMain: Bool
    let head: String
}

struct SSHRemoteRepositorySnapshot: Codable, Hashable, Sendable {
    let source: SSHRemoteRepositorySource
    let rootURL: URL
    let gitDirectoryURL: URL
    let worktrees: [SSHRemoteWorktreeSnapshot]
    let cleanupWarnings: [String]

    init(
        source: SSHRemoteRepositorySource,
        rootURL: URL,
        gitDirectoryURL: URL,
        worktrees: [SSHRemoteWorktreeSnapshot],
        cleanupWarnings: [String] = []
    ) {
        self.source = source
        self.rootURL = rootURL
        self.gitDirectoryURL = gitDirectoryURL
        self.worktrees = worktrees
        self.cleanupWarnings = cleanupWarnings
    }
}

struct SSHRemoteSynchronizationContext: Hashable, Sendable {
    let allowExistingCloneReferenceReuse: Bool

    init(allowExistingCloneReferenceReuse: Bool = false) {
        self.allowExistingCloneReferenceReuse = allowExistingCloneReferenceReuse
    }
}

struct SSHRemoteCommandResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32

    init(standardOutput: String = "", standardError: String = "", exitCode: Int32 = 0) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }

    var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: standardOutput.isEmpty || standardError.isEmpty ? "" : "\n")
    }
}

protocol SSHRemoteCommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL?
    ) async throws -> SSHRemoteCommandResult
}

protocol SSHRemoteRepositoryServicing: Sendable {
    func parseSource(_ specification: String) throws -> SSHRemoteRepositorySource
    func mirrorPath(for source: SSHRemoteRepositorySource) -> URL
    func synchronize(_ source: SSHRemoteRepositorySource) async throws -> SSHRemoteRepositorySnapshot
    func synchronize(
        _ source: SSHRemoteRepositorySource,
        context: SSHRemoteSynchronizationContext
    ) async throws -> SSHRemoteRepositorySnapshot
}

extension SSHRemoteRepositoryServicing {
    func synchronize(
        _ source: SSHRemoteRepositorySource,
        context: SSHRemoteSynchronizationContext
    ) async throws -> SSHRemoteRepositorySnapshot {
        try await synchronize(source)
    }
}

enum SSHRemoteRepositoryError: Error, Equatable, LocalizedError {
    case invalidSource
    case commandFailed(executable: String, arguments: [String], exitCode: Int32, output: String)
    case invalidRemoteOutput(String)
    case branchChanged(String)
    case incompleteHistory(branch: String, mergeBase: String)
    case unsafeManagedPath(String)
    case localMutationProtected

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "Enter a remote repository as server:/path/to/repo."
        case let .commandFailed(executable, arguments, exitCode, output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(([executable] + arguments).joined(separator: " ")) failed (\(exitCode))" +
                (detail.isEmpty ? "" : ": \(detail)")
        case let .invalidRemoteOutput(message):
            return message
        case let .branchChanged(branch):
            return "Remote branch changed while syncing \(branch); retry sync."
        case let .incompleteHistory(branch, mergeBase):
            return "Could not fetch shallow history through merge-base \(mergeBase) for \(branch)."
        case let .unsafeManagedPath(path):
            return "Refusing destructive mirror operation outside the managed cache: \(path)"
        case .localMutationProtected:
            return "Remote mirror refresh was deferred because local worktrees are currently protected."
        }
    }
}

struct FoundationSSHRemoteCommandRunner: SSHRemoteCommandRunning {
    func run(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL?
    ) async throws -> SSHRemoteCommandResult {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable.contains("/")
                ? URL(fileURLWithPath: executable)
                : URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = executable.contains("/") ? arguments : [executable] + arguments
            process.currentDirectoryURL = currentDirectoryURL

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            async let outputData = Task.detached {
                output.fileHandleForReading.readDataToEndOfFile()
            }.value
            async let errorData = Task.detached {
                error.fileHandleForReading.readDataToEndOfFile()
            }.value
            process.waitUntilExit()
            return SSHRemoteCommandResult(
                standardOutput: String(decoding: await outputData, as: UTF8.self),
                standardError: String(decoding: await errorData, as: UTF8.self),
                exitCode: process.terminationStatus
            )
        }.value
    }
}

actor SSHRemoteRepositoryService: SSHRemoteRepositoryServicing {
    nonisolated static var defaultMirrorRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/devhq/remote-mirrors", isDirectory: true)
    }

    nonisolated let mirrorRootURL: URL

    private let commandRunner: any SSHRemoteCommandRunning
    private let fileManager: FileManager
    private let mutationProtection: @Sendable (
        SSHRemoteRepositorySource,
        Set<URL>
    ) async -> Bool

    init(
        commandRunner: any SSHRemoteCommandRunning = FoundationSSHRemoteCommandRunner(),
        mirrorRootURL: URL = SSHRemoteRepositoryService.defaultMirrorRootURL,
        fileManager: FileManager = .default,
        mutationProtection: @escaping @Sendable (
            _ source: SSHRemoteRepositorySource,
            _ localWorktreeURLs: Set<URL>
        ) async -> Bool = { _, _ in true }
    ) {
        self.commandRunner = commandRunner
        self.mirrorRootURL = mirrorRootURL.standardizedFileURL
        self.fileManager = fileManager
        self.mutationProtection = mutationProtection
    }

    nonisolated func parseSource(_ specification: String) throws -> SSHRemoteRepositorySource {
        try SSHRemoteRepositorySource(specification: specification)
    }

    nonisolated func mirrorPath(for source: SSHRemoteRepositorySource) -> URL {
        var result = mirrorRootURL.appendingPathComponent(safePathComponent(source.server), isDirectory: true)
        var addedPathComponent = false
        for component in source.remotePath.split(separator: "/", omittingEmptySubsequences: true) {
            result.appendPathComponent(safePathComponent(String(component)), isDirectory: true)
            addedPathComponent = true
        }
        if !addedPathComponent {
            result.appendPathComponent("repo", isDirectory: true)
        }
        return result.standardizedFileURL
    }

    func synchronize(_ source: SSHRemoteRepositorySource) async throws -> SSHRemoteRepositorySnapshot {
        try await synchronize(source, context: SSHRemoteSynchronizationContext())
    }

    func synchronize(
        _ source: SSHRemoteRepositorySource,
        context: SSHRemoteSynchronizationContext
    ) async throws -> SSHRemoteRepositorySnapshot {
        let mirrorURL = mirrorPath(for: source)
        try requireManaged(mirrorURL)
        try fileManager.createDirectory(
            at: mirrorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let createdClone = !fileManager.fileExists(atPath: mirrorURL.appendingPathComponent(".git").path)
        if createdClone {
            _ = try await checkedRun(
                "git",
                ["clone", "--depth=1", "--no-tags", "--no-checkout", source.specification, mirrorURL.path],
                currentDirectoryURL: mirrorURL.deletingLastPathComponent()
            )
        }
        try await requireManagedRepository(at: mirrorURL)

        let remoteNames = try await inspectRemoteNames(source: source)
        let upstreams = try await inspectRemoteUpstreams(source: source)
        let remoteWorktrees = try parseWorktrees(
            try await remoteGit(source: source, arguments: ["worktree", "list", "--porcelain"])
                .standardOutput
        )
        .filter { $0.branch != nil && !$0.bare && !$0.prunable }

        var planned = [PlannedWorktree]()
        for worktree in remoteWorktrees {
            guard let branch = worktree.branch else { continue }
            let localURL = worktree.path == source.remotePath
                ? mirrorURL
                : mirrorURLForRemotePath(server: source.server, remotePath: worktree.path)
            let history = try await resolveHistory(
                source: source,
                worktree: worktree,
                upstream: upstreams[branch],
                remoteNames: remoteNames
            )
            planned.append(PlannedWorktree(
                name: branch,
                localURL: localURL,
                remotePath: worktree.path,
                isMain: worktree.path == source.remotePath,
                head: worktree.head,
                depth: history.depth,
                mergeBase: history.mergeBase
            ))
        }

        try await configureLocalRemote(at: mirrorURL, source: source)

        var depths = [String: Int]()
        for worktree in planned {
            depths[worktree.name] = max(depths[worktree.name] ?? 1, worktree.depth)
        }
        let seededBranches = createdClone || context.allowExistingCloneReferenceReuse
            ? try await seedMatchingFreshCloneBranches(
                planned: planned,
                source: source,
                mirrorURL: mirrorURL
            )
            : []
        for branch in depths.keys.sorted() {
            guard !seededBranches.contains(branch) else { continue }
            let depth = depths[branch] ?? 1
            _ = try await checkedGit(
                at: mirrorURL,
                arguments: [
                    "fetch", "--force", "--no-tags", "--depth=\(max(1, depth))", source.server,
                    "+refs/heads/\(branch):\(trackingRef(server: source.server, branch: branch))"
                ]
            )
        }

        // Validate a coherent fetched snapshot before removing or replacing
        // any checkout. A raced or incomplete fetch leaves the previous
        // worktree contents available for offline browsing and retry.
        for worktree in planned {
            let ref = trackingRef(server: source.server, branch: worktree.name)
            let fetchedHead = try await checkedGit(
                at: mirrorURL,
                arguments: ["rev-parse", "--verify", ref]
            ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard fetchedHead == worktree.head else {
                throw SSHRemoteRepositoryError.branchChanged(worktree.name)
            }
            if let mergeBase = worktree.mergeBase {
                let localBase = try await checkedGit(
                    at: mirrorURL,
                    arguments: ["merge-base", ref, mergeBase]
                ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard localBase == mergeBase else {
                    throw SSHRemoteRepositoryError.incompleteHistory(branch: ref, mergeBase: mergeBase)
                }
            }
        }

        let existing = try await localWorktreePaths(at: mirrorURL)
        let wanted = Set(planned.map { $0.localURL.standardizedFileURL })
        let stalePaths = existing
            .filter { $0 != mirrorURL && !wanted.contains($0) }
            .sorted { $0.path < $1.path }
        // Preserve the destructive-path guard as a hard failure, but validate
        // the complete cleanup set before updating or deleting anything.
        for path in stalePaths { try requireManaged(path) }
        let protectedURLs = existing.union(wanted)
        try await requireMutationAllowed(source: source, localWorktreeURLs: protectedURLs)

        for worktree in planned {
            let ref = trackingRef(server: source.server, branch: worktree.name)
            if existing.contains(worktree.localURL) {
                try requireManaged(worktree.localURL)
                try await requireManagedRepository(at: worktree.localURL)
                try await replaceCheckout(
                    at: worktree.localURL,
                    ref: ref,
                    source: source,
                    protectedURLs: protectedURLs
                )
            } else {
                try requireManaged(worktree.localURL)
                try fileManager.createDirectory(
                    at: worktree.localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try await requireMutationAllowed(
                    source: source,
                    localWorktreeURLs: protectedURLs
                )
                _ = try await checkedGit(
                    at: mirrorURL,
                    arguments: ["worktree", "add", "--detach", worktree.localURL.path, ref]
                )
            }
            try await storeParentRef(worktree.mergeBase, at: worktree.localURL)
        }

        var cleanupWarnings = [String]()
        // Keep stale worktrees intact until every wanted checkout is coherent. A
        // failed refresh can then continue exposing the last known worktree set.
        // Once cleanup begins, failures are nonfatal because the wanted
        // snapshot is coherent and cleanup cannot be rolled back.
        var skippedProtectedStaleWorktree = false
        for path in stalePaths {
            guard await mutationProtection(source, protectedURLs) else {
                skippedProtectedStaleWorktree = true
                cleanupWarnings.append(
                    "Skipped removing stale worktree \(path.path): local worktrees are currently protected."
                )
                continue
            }
            do {
                _ = try await checkedGit(
                    at: mirrorURL,
                    arguments: ["worktree", "remove", "--force", path.path]
                )
            } catch {
                cleanupWarnings.append(cleanupWarning("Remove stale worktree \(path.path)", error: error))
            }
        }
        if !skippedProtectedStaleWorktree {
            do {
                _ = try await checkedGit(at: mirrorURL, arguments: ["worktree", "prune"])
            } catch {
                cleanupWarnings.append(cleanupWarning("Prune stale worktree metadata", error: error))
            }
        }

        if !wanted.contains(mirrorURL), let first = planned.first {
            do {
                _ = try await checkedGit(
                    at: mirrorURL,
                    arguments: [
                        "update-ref", "--no-deref", "HEAD",
                        trackingRef(server: source.server, branch: first.name)
                    ]
                )
            } catch {
                cleanupWarnings.append(cleanupWarning("Update detached mirror HEAD", error: error))
            }
        }
        do {
            try await deleteRefs(
                at: mirrorURL,
                namespace: "refs/remotes",
                keeping: Set(planned.map {
                    trackingRef(server: source.server, branch: $0.name)
                })
            )
        } catch {
            cleanupWarnings.append(cleanupWarning("Prune stale remote refs", error: error))
        }
        do {
            try await deleteRefs(at: mirrorURL, namespace: "refs/tags")
        } catch {
            cleanupWarnings.append(cleanupWarning("Prune tags", error: error))
        }
        do {
            try await deleteRefs(at: mirrorURL, namespace: "refs/heads")
        } catch {
            cleanupWarnings.append(cleanupWarning("Prune local branch refs", error: error))
        }

        return SSHRemoteRepositorySnapshot(
            source: source,
            rootURL: mirrorURL,
            gitDirectoryURL: mirrorURL.appendingPathComponent(".git", isDirectory: true),
            worktrees: planned.map {
                SSHRemoteWorktreeSnapshot(
                    name: $0.name,
                    localURL: $0.localURL,
                    remotePath: $0.remotePath,
                    isMain: $0.isMain,
                    head: $0.head
                )
            },
            cleanupWarnings: cleanupWarnings
        )
    }

    private func inspectRemoteNames(source: SSHRemoteRepositorySource) async throws -> [String] {
        let output = try await remoteGit(source: source, arguments: ["remote", "-v"]).standardOutput
        var names = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 3, fields[2] == "(fetch)" {
                names.insert(String(fields[0]))
            }
        }
        return names.sorted()
    }

    private func inspectRemoteUpstreams(source: SSHRemoteRepositorySource) async throws -> [String: String] {
        let output = try await remoteGit(
            source: source,
            arguments: ["for-each-ref", "--format=%(refname:short)\t%(upstream:short)", "refs/heads"]
        ).standardOutput
        var result = [String: String]()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty {
                result[String(fields[0])] = String(fields[1])
            }
        }
        return result
    }

    private func resolveHistory(
        source: SSHRemoteRepositorySource,
        worktree: RemoteWorktree,
        upstream: String?,
        remoteNames: [String]
    ) async throws -> (depth: Int, mergeBase: String?) {
        var candidates = [String]()
        func append(_ candidate: String?) {
            guard let candidate, !candidate.isEmpty, !candidates.contains(candidate) else { return }
            candidates.append(candidate)
        }
        append(upstream)
        for remote in ["origin"] + remoteNames {
            for branch in ["main", "develop", "master"] {
                append("\(remote)/\(branch)")
            }
        }
        for branch in ["main", "develop", "master"] { append(branch) }

        for candidate in candidates {
            let result = try await remoteGit(
                source: source,
                arguments: ["merge-base", worktree.head, candidate],
                allowFailure: true
            )
            guard result.exitCode == 0, let mergeBase = parseObjectID(result.standardOutput) else { continue }
            let countResult = try await remoteGit(
                source: source,
                arguments: ["rev-list", "--count", "\(mergeBase)..\(worktree.head)"]
            )
            guard let distance = parseCount(countResult.standardOutput) else {
                throw SSHRemoteRepositoryError.invalidRemoteOutput(
                    "Could not determine shallow history depth for \(worktree.path)."
                )
            }
            return (distance + 1, mergeBase)
        }
        return (1, nil)
    }

    private func configureLocalRemote(at mirrorURL: URL, source: SSHRemoteRepositorySource) async throws {
        let existing = try await runGit(
            at: mirrorURL,
            arguments: ["remote", "get-url", source.server]
        )
        let action = existing.exitCode == 0 ? "set-url" : "add"
        _ = try await checkedGit(
            at: mirrorURL,
            arguments: ["remote", action, source.server, source.specification]
        )
    }

    private func seedMatchingFreshCloneBranches(
        planned: [PlannedWorktree],
        source: SSHRemoteRepositorySource,
        mirrorURL: URL
    ) async throws -> Set<String> {
        var seeded = Set<String>()
        for branch in Set(planned.map(\.name)).sorted() {
            let branchWorktrees = planned.filter { $0.name == branch }
            guard let expectedHead = branchWorktrees.first?.head,
                  branchWorktrees.allSatisfy({ $0.head == expectedHead })
            else { continue }

            let cloneRef = "refs/remotes/origin/\(branch)"
            let cloneHeadResult = try await runGit(
                at: mirrorURL,
                arguments: ["rev-parse", "--verify", cloneRef]
            )
            let cloneHead = cloneHeadResult.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cloneHeadResult.exitCode == 0, cloneHead == expectedHead else { continue }

            var hasRequiredHistory = true
            for worktree in branchWorktrees {
                guard let mergeBase = worktree.mergeBase else { continue }
                let baseResult = try await runGit(
                    at: mirrorURL,
                    arguments: ["merge-base", cloneRef, mergeBase]
                )
                let localBase = baseResult.standardOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if baseResult.exitCode != 0 || localBase != mergeBase {
                    hasRequiredHistory = false
                    break
                }
            }
            guard hasRequiredHistory else { continue }

            _ = try await checkedGit(
                at: mirrorURL,
                arguments: [
                    "update-ref",
                    trackingRef(server: source.server, branch: branch),
                    expectedHead
                ]
            )
            seeded.insert(branch)
        }
        return seeded
    }

    private func localWorktreePaths(at mirrorURL: URL) async throws -> Set<URL> {
        let output = try await checkedGit(
            at: mirrorURL,
            arguments: ["worktree", "list", "--porcelain"]
        ).standardOutput
        return Set(try parseWorktrees(output).map { URL(fileURLWithPath: $0.path).standardizedFileURL })
    }

    private func replaceCheckout(
        at path: URL,
        ref: String,
        source: SSHRemoteRepositorySource,
        protectedURLs: Set<URL>
    ) async throws {
        try await requireMutationAllowed(source: source, localWorktreeURLs: protectedURLs)
        _ = try await checkedGit(at: path, arguments: ["clean", "-fd"])
        try await requireMutationAllowed(source: source, localWorktreeURLs: protectedURLs)
        _ = try await checkedGit(at: path, arguments: ["checkout", "-f", "--detach", ref])
        try await requireMutationAllowed(source: source, localWorktreeURLs: protectedURLs)
        _ = try await checkedGit(at: path, arguments: ["reset", "--hard", ref])
        try await requireMutationAllowed(source: source, localWorktreeURLs: protectedURLs)
        _ = try await checkedGit(at: path, arguments: ["clean", "-fd"])
    }

    private func requireMutationAllowed(
        source: SSHRemoteRepositorySource,
        localWorktreeURLs: Set<URL>
    ) async throws {
        guard await mutationProtection(source, localWorktreeURLs) else {
            throw SSHRemoteRepositoryError.localMutationProtected
        }
    }

    private func storeParentRef(_ parent: String?, at worktreeURL: URL) async throws {
        let gitDirectory = try await checkedGit(
            at: worktreeURL,
            arguments: ["rev-parse", "--path-format=absolute", "--git-dir"]
        ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDirectory.isEmpty else {
            throw SSHRemoteRepositoryError.invalidRemoteOutput("Could not locate mirror git directory.")
        }
        let directoryURL = URL(fileURLWithPath: gitDirectory, isDirectory: true)
        try requireManaged(directoryURL)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try ((parent ?? "") + "\n").write(
            to: directoryURL.appendingPathComponent("devhq-parent-ref"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func deleteRefs(
        at mirrorURL: URL,
        namespace: String,
        keeping retainedRefs: Set<String> = []
    ) async throws {
        let output = try await checkedGit(
            at: mirrorURL,
            arguments: ["for-each-ref", "--format=%(refname)", namespace]
        ).standardOutput
        for ref in output.split(whereSeparator: \.isNewline).map(String.init)
            where !ref.isEmpty && !retainedRefs.contains(ref) {
            _ = try await checkedGit(at: mirrorURL, arguments: ["update-ref", "-d", ref])
        }
    }

    private func cleanupWarning(_ operation: String, error: Error) -> String {
        "\(operation): \(error.localizedDescription)"
    }

    private func requireManagedRepository(at worktreeURL: URL) async throws {
        for argument in ["--git-dir", "--git-common-dir"] {
            let path = try await checkedGit(
                at: worktreeURL,
                arguments: ["rev-parse", "--path-format=absolute", argument]
            ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                throw SSHRemoteRepositoryError.invalidRemoteOutput(
                    "Could not locate managed repository metadata."
                )
            }
            try requireManaged(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private func remoteGit(
        source: SSHRemoteRepositorySource,
        arguments: [String],
        allowFailure: Bool = false
    ) async throws -> SSHRemoteCommandResult {
        var script = "git -C \(shellQuote(source.remotePath))"
        for argument in arguments { script += " \(shellQuote(argument))" }
        let command = "/bin/sh -lc \(shellQuote(script))"
        let result = try await commandRunner.run(
            executable: "ssh",
            arguments: [source.server, command],
            currentDirectoryURL: nil
        )
        if !allowFailure, result.exitCode != 0 {
            throw SSHRemoteRepositoryError.commandFailed(
                executable: "ssh",
                arguments: [source.server, command],
                exitCode: result.exitCode,
                output: result.combinedOutput
            )
        }
        return result
    }

    private func checkedGit(at url: URL, arguments: [String]) async throws -> SSHRemoteCommandResult {
        try await checkedRun("git", ["-C", url.path] + arguments, currentDirectoryURL: url)
    }

    private func runGit(at url: URL, arguments: [String]) async throws -> SSHRemoteCommandResult {
        try await commandRunner.run(
            executable: "git",
            arguments: ["-C", url.path] + arguments,
            currentDirectoryURL: url
        )
    }

    private func checkedRun(
        _ executable: String,
        _ arguments: [String],
        currentDirectoryURL: URL?
    ) async throws -> SSHRemoteCommandResult {
        let result = try await commandRunner.run(
            executable: executable,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL
        )
        guard result.exitCode == 0 else {
            throw SSHRemoteRepositoryError.commandFailed(
                executable: executable,
                arguments: arguments,
                exitCode: result.exitCode,
                output: result.combinedOutput
            )
        }
        return result
    }

    private func requireManaged(_ url: URL) throws {
        let root = mirrorRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard candidate == root || candidate.hasPrefix(root + "/") else {
            throw SSHRemoteRepositoryError.unsafeManagedPath(candidate)
        }
    }

    private nonisolated func mirrorURLForRemotePath(server: String, remotePath: String) -> URL {
        let source = try? SSHRemoteRepositorySource(server: server, remotePath: remotePath)
        return source.map(mirrorPath(for:))
            ?? mirrorRootURL.appendingPathComponent(safePathComponent(server)).appendingPathComponent("repo")
    }
}

private struct RemoteWorktree {
    let path: String
    var head = ""
    var branch: String?
    var bare = false
    var prunable = false
}

private struct PlannedWorktree {
    let name: String
    let localURL: URL
    let remotePath: String
    let isMain: Bool
    let head: String
    let depth: Int
    let mergeBase: String?
}

private func parseWorktrees(_ output: String) throws -> [RemoteWorktree] {
    var result = [RemoteWorktree]()
    var current: RemoteWorktree?
    for lineSlice in output.split(whereSeparator: \.isNewline) {
        let line = String(lineSlice)
        if line.hasPrefix("worktree ") {
            if let current { result.append(current) }
            current = RemoteWorktree(path: String(line.dropFirst("worktree ".count)))
        } else if line.hasPrefix("HEAD ") {
            current?.head = String(line.dropFirst("HEAD ".count))
        } else if line.hasPrefix("branch refs/heads/") {
            current?.branch = String(line.dropFirst("branch refs/heads/".count))
        } else if line == "bare" {
            current?.bare = true
        } else if line.hasPrefix("prunable") {
            current?.prunable = true
        }
    }
    if let current { result.append(current) }
    return result
}

private func safePathComponent(_ value: String) -> String {
    switch value {
    case ".": return "_dot"
    case "..": return "_dotdot"
    default: return value.replacingOccurrences(of: "/", with: "_")
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func trackingRef(server: String, branch: String) -> String {
    "refs/remotes/\(server)/\(branch)"
}

private func parseObjectID(_ output: String) -> String? {
    output.split(whereSeparator: \.isNewline).reversed().lazy
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { value in
            (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
        }
}

private func parseCount(_ output: String) -> Int? {
    output.split(whereSeparator: \.isNewline).reversed().lazy
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .compactMap(Int.init)
        .first
}
