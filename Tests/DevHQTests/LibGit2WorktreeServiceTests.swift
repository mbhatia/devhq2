import Foundation
import XCTest
@testable import DevHQ

final class LibGit2WorktreeServiceTests: XCTestCase {
    func testDiscoversMainAndLinkedWorktreesFromMainRepository() throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let repository = try LibGit2WorktreeService().discover(at: fixture.main)

        XCTAssertEqual(repository.rootURL, normalized(fixture.main))
        XCTAssertEqual(repository.id, normalized(fixture.main).path)
        XCTAssertEqual(repository.name, "repository")
        XCTAssertEqual(repository.gitDirectoryURL, normalized(fixture.main.appendingPathComponent(".git")))
        XCTAssertEqual(
            repository.worktrees,
            [
                GitWorktreeInfo(name: "main", url: fixture.main, isMain: true),
                GitWorktreeInfo(name: "feature/a", url: fixture.linkedA, isMain: false),
                GitWorktreeInfo(name: "feature/b", url: fixture.linkedB, isMain: false)
            ]
        )
    }

    func testUsesCheckedOutBranchNamesInsteadOfWorktreeDirectoryNames() throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let repository = try LibGit2WorktreeService().discover(at: fixture.main)

        XCTAssertEqual(fixture.linkedA.lastPathComponent, "linked-a")
        XCTAssertEqual(repository.worktrees.first { $0.url == normalized(fixture.linkedA) }?.name, "feature/a")
    }

    func testUsesAbbreviatedCommitForDetachedHeadName() throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try runGit(["-C", fixture.linkedA.path, "checkout", "--detach"])
        let abbreviatedCommit = try runGitOutput([
            "-C", fixture.linkedA.path, "rev-parse", "--short=7", "HEAD"
        ])

        let repository = try LibGit2WorktreeService().discover(at: fixture.main)

        XCTAssertEqual(
            repository.worktrees.first { $0.url == normalized(fixture.linkedA) }?.name,
            "detached@\(abbreviatedCommit)"
        )
    }

    func testUsesCheckedOutBranchNameForEmptyRepository() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repositoryURL = container.appendingPathComponent("empty-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try runGit(["init", "-b", "fresh-branch", repositoryURL.path])

        let repository = try LibGit2WorktreeService().discover(at: repositoryURL)

        XCTAssertEqual(
            repository.worktrees,
            [GitWorktreeInfo(name: "fresh-branch", url: repositoryURL, isMain: true)]
        )
    }

    func testNormalizesLinkedWorktreeInputToCommonRepository() throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = LibGit2WorktreeService()

        let fromMain = try service.discover(at: fixture.main)
        let fromLinked = try service.discover(at: fixture.linkedA)

        XCTAssertEqual(fromLinked, fromMain)
        XCTAssertEqual(fromLinked.worktrees.map(\.id), fromLinked.worktrees.map { $0.url.path })
    }

    func testDiscoversRepositoryUsingRelativeWorktreesExtension() throws {
        let fixture = try makeRepositoryFixture(relativeWorktreePaths: true)
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let linkedGitFile = try String(
            contentsOf: fixture.linkedA.appendingPathComponent(".git"),
            encoding: .utf8
        )
        XCTAssertEqual(linkedGitFile, "gitdir: ../repository/.git/worktrees/linked-a\n")

        let repository = try LibGit2WorktreeService().discover(at: fixture.main)

        XCTAssertEqual(repository.rootURL, normalized(fixture.main))
        XCTAssertEqual(
            repository.worktrees.map(\.url),
            [fixture.main, fixture.linkedA, fixture.linkedB].map(normalized)
        )
    }

    func testRejectsDirectoryThatIsNotARepository() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try LibGit2WorktreeService().discover(at: directory)) { error in
            XCTAssertTrue(error is LibGit2WorktreeError)
        }
    }

    func testCreatesNamespacedBranchFromHead() throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let destination = fixture.container
            .appendingPathComponent(".worktrees/feature/new", isDirectory: true)
        let head = try runGitOutput(["-C", fixture.main.path, "rev-parse", "HEAD"])

        let created = try LibGit2WorktreeService().createWorktree(
            in: fixture.main,
            branchName: "feature/new",
            at: destination
        )

        XCTAssertEqual(
            created,
            GitWorktreeInfo(name: "feature/new", url: destination, isMain: false)
        )
        XCTAssertEqual(try runGitOutput(["-C", destination.path, "branch", "--show-current"]), "feature/new")
        XCTAssertEqual(try runGitOutput(["-C", destination.path, "rev-parse", "HEAD"]), head)
    }

    func testCreatesWorktreeForExistingLocalBranch() throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let destination = fixture.container.appendingPathComponent("existing", isDirectory: true)
        try runGit(["-C", fixture.main.path, "branch", "existing"])

        try LibGit2WorktreeService().createWorktree(
            in: fixture.linkedA,
            branchName: "existing",
            at: destination
        )

        XCTAssertEqual(try runGitOutput(["-C", destination.path, "branch", "--show-current"]), "existing")
    }

    func testCreatesTrackingWorktreeForUniqueRemoteBranch() throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let remote = fixture.container.appendingPathComponent("remote.git", isDirectory: true)
        let destination = fixture.container.appendingPathComponent("review", isDirectory: true)
        try runGit(["init", "--bare", remote.path])
        try runGit(["-C", fixture.main.path, "remote", "add", "origin", remote.path])

        try "remote branch\n".write(
            to: fixture.linkedA.appendingPathComponent("remote.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["-C", fixture.linkedA.path, "add", "remote.txt"])
        try commit(in: fixture.linkedA, message: "Remote branch commit")
        let remoteHead = try runGitOutput(["-C", fixture.linkedA.path, "rev-parse", "HEAD"])
        try runGit([
            "-C", fixture.linkedA.path,
            "push", "origin", "HEAD:refs/heads/review"
        ])

        try LibGit2WorktreeService().createWorktree(
            in: fixture.main,
            branchName: "review",
            at: destination
        )

        XCTAssertEqual(try runGitOutput(["-C", destination.path, "rev-parse", "HEAD"]), remoteHead)
        XCTAssertEqual(
            try runGitOutput([
                "-C", destination.path,
                "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"
            ]),
            "origin/review"
        )
    }

    func testRejectsBranchFoundOnMultipleRemotes() throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let origin = fixture.container.appendingPathComponent("origin.git", isDirectory: true)
        let upstream = fixture.container.appendingPathComponent("upstream.git", isDirectory: true)
        try runGit(["init", "--bare", origin.path])
        try runGit(["init", "--bare", upstream.path])
        try runGit(["-C", fixture.main.path, "remote", "add", "origin", origin.path])
        try runGit(["-C", fixture.main.path, "remote", "add", "upstream", upstream.path])
        try runGit(["-C", fixture.main.path, "push", "origin", "HEAD:refs/heads/shared"])
        try runGit(["-C", fixture.main.path, "push", "upstream", "HEAD:refs/heads/shared"])
        let destination = fixture.container.appendingPathComponent("shared", isDirectory: true)

        XCTAssertThrowsError(
            try LibGit2WorktreeService().createWorktree(
                in: fixture.main,
                branchName: "shared",
                at: destination
            )
        ) { error in
            guard case let LibGit2WorktreeError.ambiguousRemoteBranch(name, branches) = error else {
                return XCTFail("Expected ambiguousRemoteBranch, got \(error)")
            }
            XCTAssertEqual(name, "shared")
            XCTAssertEqual(branches.sorted(), ["origin/shared", "upstream/shared"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testNestedRemoteBranchDoesNotCreateFalseShortNameAmbiguity() throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let origin = fixture.container.appendingPathComponent("origin.git", isDirectory: true)
        let upstream = fixture.container.appendingPathComponent("upstream.git", isDirectory: true)
        try runGit(["init", "--bare", origin.path])
        try runGit(["init", "--bare", upstream.path])
        try runGit(["-C", fixture.main.path, "remote", "add", "origin", origin.path])
        try runGit(["-C", fixture.main.path, "remote", "add", "upstream", upstream.path])
        try runGit(["-C", fixture.main.path, "push", "origin", "HEAD:refs/heads/team/foo"])

        try "upstream branch\n".write(
            to: fixture.linkedA.appendingPathComponent("upstream.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["-C", fixture.linkedA.path, "add", "upstream.txt"])
        try commit(in: fixture.linkedA, message: "Upstream branch commit")
        let upstreamHead = try runGitOutput(["-C", fixture.linkedA.path, "rev-parse", "HEAD"])
        try runGit(["-C", fixture.linkedA.path, "push", "upstream", "HEAD:refs/heads/foo"])
        let destination = fixture.container.appendingPathComponent("foo", isDirectory: true)

        try LibGit2WorktreeService().createWorktree(
            in: fixture.main,
            branchName: "foo",
            at: destination
        )

        XCTAssertEqual(try runGitOutput(["-C", destination.path, "rev-parse", "HEAD"]), upstreamHead)
        XCTAssertEqual(
            try runGitOutput([
                "-C", destination.path,
                "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"
            ]),
            "upstream/foo"
        )
    }

    func testRejectsInvalidBranchExistingPathAndCheckedOutBranch() throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = LibGit2WorktreeService()

        XCTAssertThrowsError(
            try service.createWorktree(
                in: fixture.main,
                branchName: "invalid branch",
                at: fixture.container.appendingPathComponent("invalid")
            )
        ) { error in
            guard case LibGit2WorktreeError.invalidBranchName = error else {
                return XCTFail("Expected invalidBranchName, got \(error)")
            }
        }

        let existingPath = fixture.container.appendingPathComponent("already-here")
        try FileManager.default.createDirectory(at: existingPath, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try service.createWorktree(
                in: fixture.main,
                branchName: "valid-branch",
                at: existingPath
            )
        ) { error in
            guard case LibGit2WorktreeError.worktreePathExists = error else {
                return XCTFail("Expected worktreePathExists, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try service.createWorktree(
                in: fixture.main,
                branchName: "feature/a",
                at: fixture.container.appendingPathComponent("duplicate-checkout")
            )
        ) { error in
            guard case LibGit2WorktreeError.branchAlreadyCheckedOut = error else {
                return XCTFail("Expected branchAlreadyCheckedOut, got \(error)")
            }
        }
    }

    func testDeletesCleanLinkedWorktreeAndKeepsBranch() throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        try LibGit2WorktreeService().deleteWorktree(
            in: fixture.main,
            at: fixture.linkedA
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linkedA.path))
        try runGit([
            "-C", fixture.main.path,
            "show-ref", "--verify", "--quiet", "refs/heads/feature/a"
        ])
        let repository = try LibGit2WorktreeService().discover(at: fixture.main)
        XCTAssertFalse(repository.worktrees.contains { $0.name == "feature/a" })
    }

    func testRejectsDeletingMainWorktree() throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        XCTAssertThrowsError(
            try LibGit2WorktreeService().deleteWorktree(
                in: fixture.linkedA,
                at: fixture.main
            )
        ) { error in
            guard case LibGit2WorktreeError.cannotDeleteMainWorktree = error else {
                return XCTFail("Expected cannotDeleteMainWorktree, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.main.path))
    }

    func testRejectsDeletingWorktreeWithStagedChanges() throws {
        try assertDeleteRejectedForChanges { fixture in
            try "staged\n".write(
                to: fixture.linkedA.appendingPathComponent("staged.txt"),
                atomically: true,
                encoding: .utf8
            )
            try self.runGit(["-C", fixture.linkedA.path, "add", "staged.txt"])
        }
    }

    func testRejectsDeletingWorktreeWithUnstagedChanges() throws {
        try assertDeleteRejectedForChanges { fixture in
            try "modified\n".write(
                to: fixture.linkedA.appendingPathComponent("README.md"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func testRejectsDeletingWorktreeWithUntrackedFiles() throws {
        try assertDeleteRejectedForChanges { fixture in
            try "untracked\n".write(
                to: fixture.linkedA.appendingPathComponent("untracked.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func testRejectsDeletingWorktreeWithConflicts() throws {
        try assertDeleteRejectedForChanges { fixture in
            let readme = fixture.main.appendingPathComponent("README.md")
            try "main change\n".write(to: readme, atomically: true, encoding: .utf8)
            try self.runGit(["-C", fixture.main.path, "add", "README.md"])
            try self.commit(in: fixture.main, message: "Main change")

            let linkedReadme = fixture.linkedA.appendingPathComponent("README.md")
            try "feature change\n".write(to: linkedReadme, atomically: true, encoding: .utf8)
            try self.runGit(["-C", fixture.linkedA.path, "add", "README.md"])
            try self.commit(in: fixture.linkedA, message: "Feature change")

            let mergeStatus = self.runGitResult([
                "-C", fixture.linkedA.path, "merge", "main"
            ]).status
            XCTAssertNotEqual(mergeStatus, 0)
        }
    }

    private func assertDeleteRejectedForChanges(
        prepare: ((container: URL, main: URL, linkedA: URL, linkedB: URL)) throws -> Void
    ) throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try prepare(fixture)

        XCTAssertThrowsError(
            try LibGit2WorktreeService().deleteWorktree(
                in: fixture.main,
                at: fixture.linkedA
            )
        ) { error in
            guard case LibGit2WorktreeError.worktreeHasChanges = error else {
                return XCTFail("Expected worktreeHasChanges, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.linkedA.path))
    }

    private func makeRepositoryFixture(relativeWorktreePaths: Bool = false) throws -> (
        container: URL,
        main: URL,
        linkedA: URL,
        linkedB: URL
    ) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let main = container.appendingPathComponent("repository", isDirectory: true)
        let linkedA = container.appendingPathComponent("linked-a", isDirectory: true)
        let linkedB = container.appendingPathComponent("linked-b", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        do {
            try runGit(["init", "-b", "main", main.path])
            try "fixture\n".write(
                to: main.appendingPathComponent("README.md"),
                atomically: true,
                encoding: .utf8
            )
            try runGit(["-C", main.path, "add", "README.md"])
            try runGit([
                "-C", main.path,
                "-c", "user.name=DevHQ Tests",
                "-c", "user.email=devhq-tests@example.invalid",
                "commit", "-m", "Initial commit"
            ])
            let pathArguments = relativeWorktreePaths ? ["--relative-paths"] : []
            try runGit(
                ["-C", main.path, "worktree", "add"]
                    + pathArguments
                    + ["-b", "feature/a", linkedA.path]
            )
            try runGit(
                ["-C", main.path, "worktree", "add"]
                    + pathArguments
                    + ["-b", "feature/b", linkedB.path]
            )
        } catch {
            try? FileManager.default.removeItem(at: container)
            throw error
        }

        return (container, main, linkedA, linkedB)
    }

    private func runGit(_ arguments: [String]) throws {
        _ = try runGitOutput(arguments)
    }

    private func runGitOutput(_ arguments: [String]) throws -> String {
        let result = runGitResult(arguments)
        guard result.status == 0 else {
            throw NSError(
                domain: "LibGit2WorktreeServiceTests",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.output]
            )
        }
        return result.output
    }

    private func runGitResult(_ arguments: [String]) -> (status: Int32, output: String) {
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

    private func commit(in repository: URL, message: String) throws {
        try runGit([
            "-C", repository.path,
            "-c", "user.name=DevHQ Tests",
            "-c", "user.email=devhq-tests@example.invalid",
            "commit", "-m", message
        ])
    }

    private func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
