import CLibgit2
import Foundation

enum LibGit2WorktreeError: LocalizedError {
    case notRepository(URL, String)
    case missingMainWorktree(URL)
    case invalidBranchName(String)
    case worktreePathExists(URL)
    case branchAlreadyCheckedOut(String)
    case ambiguousRemoteBranch(String, [String])
    case worktreeNotFound(URL)
    case cannotDeleteMainWorktree(URL)
    case worktreeHasChanges(URL)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .notRepository(url, detail):
            "Could not open a Git repository at \(url.path): \(detail)"
        case let .missingMainWorktree(url):
            "The Git repository at \(url.path) does not have a main worktree."
        case let .invalidBranchName(branchName):
            "'\(branchName)' is not a valid Git branch name."
        case let .worktreePathExists(url):
            "A file or directory already exists at \(url.path)."
        case let .branchAlreadyCheckedOut(branchName):
            "The branch '\(branchName)' is already checked out in another worktree."
        case let .ambiguousRemoteBranch(branchName, remoteBranches):
            "Multiple remote branches match '\(branchName)': \(remoteBranches.joined(separator: ", "))."
        case let .worktreeNotFound(url):
            "No Git worktree is registered at \(url.path)."
        case let .cannotDeleteMainWorktree(url):
            "The main worktree at \(url.path) cannot be deleted."
        case let .worktreeHasChanges(url):
            "The worktree at \(url.path) has staged, unstaged, untracked, or conflicted changes."
        case let .operationFailed(detail):
            detail
        }
    }
}

protocol GitWorktreeManaging {
    @discardableResult
    func createWorktree(
        in repositoryURL: URL,
        branchName: String,
        at worktreeURL: URL
    ) throws -> GitWorktreeInfo

    func deleteWorktree(in repositoryURL: URL, at worktreeURL: URL) throws
}

final class LibGit2WorktreeService: GitWorktreeDiscovering, GitWorktreeManaging {
    private static let initializationError: LibGit2WorktreeError? = {
        let initializationResult = git_libgit2_init()
        guard initializationResult >= 0 else {
            return .operationFailed(
                "Initialize libgit2 failed: \(lastErrorMessage(for: initializationResult))"
            )
        }

        let extensionResult = "relativeworktrees".withCString { relativeWorktrees in
            var extensions: [UnsafePointer<CChar>?] = [relativeWorktrees]
            return extensions.withUnsafeMutableBufferPointer { buffer in
                devhq_git_libgit2_set_extensions(buffer.baseAddress, buffer.count)
            }
        }
        guard extensionResult == 0 else {
            return .operationFailed(
                "Register libgit2 extensions failed: \(lastErrorMessage(for: extensionResult))"
            )
        }

        return nil
    }()

    init() {
        _ = Self.initializationError
    }

    func discover(at url: URL) throws -> GitRepositoryInfo {
        if let initializationError = Self.initializationError {
            throw initializationError
        }

        let requestedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let openedRepository = try openRepository(at: requestedURL)
        defer { git_repository_free(openedRepository) }

        guard let commonDirectoryPath = git_repository_commondir(openedRepository) else {
            throw LibGit2WorktreeError.operationFailed("libgit2 did not return the repository's common directory.")
        }

        let commonDirectoryURL = normalizedFileURL(String(cString: commonDirectoryPath))
        let commonRepository = try openRepository(at: commonDirectoryURL)
        defer { git_repository_free(commonRepository) }

        guard let mainWorktreePath = git_repository_workdir(commonRepository) else {
            throw LibGit2WorktreeError.missingMainWorktree(requestedURL)
        }

        let mainWorktreeURL = normalizedFileURL(String(cString: mainWorktreePath))
        var worktrees = [
            GitWorktreeInfo(
                name: try worktreeDisplayName(at: mainWorktreeURL),
                url: mainWorktreeURL,
                isMain: true
            )
        ]

        var names = git_strarray()
        defer { git_strarray_dispose(&names) }
        try check(
            git_worktree_list(&names, commonRepository),
            operation: "List Git worktrees"
        )

        if let strings = names.strings {
            for index in 0..<names.count {
                guard let namePointer = strings[index] else { continue }
                let name = String(cString: namePointer)
                var worktree: OpaquePointer?
                let lookupResult = name.withCString {
                    git_worktree_lookup(&worktree, commonRepository, $0)
                }
                try check(
                    lookupResult,
                    operation: "Look up Git worktree '\(name)'"
                )
                guard let worktree else {
                    throw LibGit2WorktreeError.operationFailed(
                        "libgit2 returned no worktree for '\(name)'."
                    )
                }
                defer { git_worktree_free(worktree) }

                guard let path = git_worktree_path(worktree) else {
                    throw LibGit2WorktreeError.operationFailed(
                        "libgit2 returned no path for worktree '\(name)'."
                    )
                }
                let worktreeURL = normalizedFileURL(String(cString: path))
                worktrees.append(
                    GitWorktreeInfo(
                        name: try worktreeDisplayName(at: worktreeURL),
                        url: worktreeURL,
                        isMain: false
                    )
                )
            }
        }

        let linkedWorktrees = worktrees.dropFirst().sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        worktrees = [worktrees[0]] + linkedWorktrees

        return GitRepositoryInfo(
            rootURL: mainWorktreeURL,
            name: mainWorktreeURL.lastPathComponent,
            gitDirectoryURL: commonDirectoryURL,
            worktrees: worktrees
        )
    }

    @discardableResult
    func createWorktree(
        in repositoryURL: URL,
        branchName: String,
        at worktreeURL: URL
    ) throws -> GitWorktreeInfo {
        let repositoryURL = normalizedFileURL(repositoryURL.path)
        let worktreeURL = normalizedFileURL(worktreeURL.path)

        try validateRepository(at: repositoryURL)
        try validateBranchName(branchName, in: repositoryURL)

        guard !FileManager.default.fileExists(atPath: worktreeURL.path) else {
            throw LibGit2WorktreeError.worktreePathExists(worktreeURL)
        }

        let worktreeList = try gitOutput(
            ["-C", repositoryURL.path, "worktree", "list", "--porcelain"],
            operation: "List Git worktrees"
        )
        if worktreeList.split(separator: "\n").contains("branch refs/heads/\(branchName)"[...]) {
            throw LibGit2WorktreeError.branchAlreadyCheckedOut(branchName)
        }

        let branchExists = try localBranchExists(branchName, in: repositoryURL)
        let arguments: [String]
        if branchExists {
            arguments = [
                "-C", repositoryURL.path,
                "worktree", "add", worktreeURL.path, branchName
            ]
        } else {
            let remoteBranches = try matchingRemoteBranches(
                branchName,
                in: repositoryURL
            )
            guard remoteBranches.count <= 1 else {
                throw LibGit2WorktreeError.ambiguousRemoteBranch(
                    branchName,
                    remoteBranches
                )
            }
            if let remoteBranch = remoteBranches.first {
                arguments = [
                    "-C", repositoryURL.path,
                    "worktree", "add", "--track", "-b", branchName,
                    worktreeURL.path, remoteBranch
                ]
            } else {
                arguments = [
                    "-C", repositoryURL.path,
                    "worktree", "add", "-b", branchName, worktreeURL.path, "HEAD"
                ]
            }
        }
        _ = try gitOutput(arguments, operation: "Create Git worktree")

        return GitWorktreeInfo(name: branchName, url: worktreeURL, isMain: false)
    }

    func deleteWorktree(in repositoryURL: URL, at worktreeURL: URL) throws {
        let repositoryURL = normalizedFileURL(repositoryURL.path)
        let worktreeURL = normalizedFileURL(worktreeURL.path)

        try validateRepository(at: repositoryURL)
        let entries = parseWorktreePaths(
            try gitOutput(
                ["-C", repositoryURL.path, "worktree", "list", "--porcelain"],
                operation: "List Git worktrees"
            )
        )
        guard let mainWorktreeURL = entries.first else {
            throw LibGit2WorktreeError.missingMainWorktree(repositoryURL)
        }
        guard entries.contains(worktreeURL) else {
            throw LibGit2WorktreeError.worktreeNotFound(worktreeURL)
        }
        guard worktreeURL != mainWorktreeURL else {
            throw LibGit2WorktreeError.cannotDeleteMainWorktree(worktreeURL)
        }

        let status = try gitOutput(
            [
                "-C", worktreeURL.path,
                "status", "--porcelain=v1", "--untracked-files=all", "--ignored=no"
            ],
            operation: "Check Git worktree status"
        )
        guard status.isEmpty else {
            throw LibGit2WorktreeError.worktreeHasChanges(worktreeURL)
        }

        _ = try gitOutput(
            ["-C", repositoryURL.path, "worktree", "remove", "--", worktreeURL.path],
            operation: "Delete Git worktree"
        )
    }

    private func validateRepository(at url: URL) throws {
        let result = runGit(["-C", url.path, "rev-parse", "--git-dir"])
        guard result.status == 0 else {
            throw LibGit2WorktreeError.notRepository(url, result.output)
        }
    }

    private func validateBranchName(_ branchName: String, in repositoryURL: URL) throws {
        guard !branchName.isEmpty, !branchName.hasPrefix("-") else {
            throw LibGit2WorktreeError.invalidBranchName(branchName)
        }
        let result = runGit([
            "-C", repositoryURL.path,
            "check-ref-format", "--branch", branchName
        ])
        guard result.status == 0 else {
            throw LibGit2WorktreeError.invalidBranchName(branchName)
        }
    }

    private func localBranchExists(_ branchName: String, in repositoryURL: URL) throws -> Bool {
        let result = runGit([
            "-C", repositoryURL.path,
            "show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"
        ])
        switch result.status {
        case 0:
            return true
        case 1:
            return false
        default:
            throw LibGit2WorktreeError.operationFailed(
                "Check Git branch '\(branchName)' failed: \(result.output)"
            )
        }
    }

    private func matchingRemoteBranches(
        _ branchName: String,
        in repositoryURL: URL
    ) throws -> [String] {
        let output = try gitOutput(
            [
                "-C", repositoryURL.path,
                "for-each-ref", "--format=%(refname) %(symref)", "refs/remotes"
            ],
            operation: "List remote Git branches"
        )
        let prefix = "refs/remotes/"
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 1 else { return nil }
            let reference = String(fields[0])
            guard reference.hasPrefix(prefix) else { return nil }
            let shortName = String(reference.dropFirst(prefix.count))
            guard
                let separator = shortName.firstIndex(of: "/"),
                shortName[shortName.index(after: separator)...] == branchName
            else { return nil }
            return shortName
        }
    }

    private func parseWorktreePaths(_ output: String) -> [URL] {
        output.split(separator: "\n").compactMap { line in
            let prefix = "worktree "
            guard line.hasPrefix(prefix) else { return nil }
            return normalizedFileURL(String(line.dropFirst(prefix.count)))
        }
    }

    private func gitOutput(_ arguments: [String], operation: String) throws -> String {
        let result = runGit(arguments)
        guard result.status == 0 else {
            let detail = result.output.isEmpty
                ? "git exited with status \(result.status)"
                : result.output
            throw LibGit2WorktreeError.operationFailed("\(operation) failed: \(detail)")
        }
        return result.output
    }

    private func runGit(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func openRepository(at url: URL) throws -> OpaquePointer {
        var repository: OpaquePointer?
        let result = url.withUnsafeFileSystemRepresentation { path in
            git_repository_open(&repository, path)
        }
        guard result == 0, let repository else {
            throw LibGit2WorktreeError.notRepository(url, lastErrorMessage(for: result))
        }
        return repository
    }

    private func worktreeDisplayName(at url: URL) throws -> String {
        let repository = try openRepository(at: url)
        defer { git_repository_free(repository) }

        var head: OpaquePointer?
        let headResult = git_repository_head(&head, repository)
        if headResult != 0, git_repository_head_unborn(repository) == 1 {
            return try unbornBranchName(in: repository, at: url)
        }
        try check(headResult, operation: "Resolve HEAD for worktree at \(url.path)")
        guard let head else {
            throw LibGit2WorktreeError.operationFailed(
                "libgit2 returned no HEAD for worktree at \(url.path)."
            )
        }
        defer { git_reference_free(head) }

        let detachedResult = git_repository_head_detached(repository)
        guard detachedResult >= 0 else {
            throw LibGit2WorktreeError.operationFailed(
                "Check detached HEAD for worktree at \(url.path) failed: \(lastErrorMessage(for: detachedResult))"
            )
        }

        if detachedResult == 1 {
            guard
                let target = git_reference_target(head),
                let oidString = git_oid_tostr_s(target)
            else {
                throw LibGit2WorktreeError.operationFailed(
                    "libgit2 returned no commit for detached HEAD at \(url.path)."
                )
            }
            return "detached@\(String(cString: oidString).prefix(7))"
        }

        guard let shorthand = git_reference_shorthand(head) else {
            throw LibGit2WorktreeError.operationFailed(
                "libgit2 returned no branch name for worktree at \(url.path)."
            )
        }
        return String(cString: shorthand)
    }

    private func unbornBranchName(in repository: OpaquePointer, at url: URL) throws -> String {
        var head: OpaquePointer?
        let lookupResult = "HEAD".withCString {
            git_reference_lookup(&head, repository, $0)
        }
        try check(lookupResult, operation: "Resolve unborn HEAD for worktree at \(url.path)")
        guard let head else {
            throw LibGit2WorktreeError.operationFailed(
                "libgit2 returned no unborn HEAD for worktree at \(url.path)."
            )
        }
        defer { git_reference_free(head) }

        guard let target = git_reference_symbolic_target(head) else {
            throw LibGit2WorktreeError.operationFailed(
                "libgit2 returned no branch for unborn HEAD at \(url.path)."
            )
        }

        let fullName = String(cString: target)
        let branchPrefix = "refs/heads/"
        guard fullName.hasPrefix(branchPrefix), fullName.count > branchPrefix.count else {
            throw LibGit2WorktreeError.operationFailed(
                "libgit2 returned invalid unborn branch '\(fullName)' at \(url.path)."
            )
        }
        return String(fullName.dropFirst(branchPrefix.count))
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw LibGit2WorktreeError.operationFailed(
                "\(operation) failed: \(lastErrorMessage(for: result))"
            )
        }
    }

    private static func lastErrorMessage(for result: Int32) -> String {
        guard let error = git_error_last(), let message = error.pointee.message else {
            return "libgit2 error \(result)"
        }
        return String(cString: message)
    }

    private func lastErrorMessage(for result: Int32) -> String {
        Self.lastErrorMessage(for: result)
    }

    private func normalizedFileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}
