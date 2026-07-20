import CLibgit2
import Foundation

enum LibGit2WorktreeError: LocalizedError {
    case notRepository(URL, String)
    case missingMainWorktree(URL)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .notRepository(url, detail):
            "Could not open a Git repository at \(url.path): \(detail)"
        case let .missingMainWorktree(url):
            "The Git repository at \(url.path) does not have a main worktree."
        case let .operationFailed(detail):
            detail
        }
    }
}

final class LibGit2WorktreeService: GitWorktreeDiscovering {
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
