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
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            throw NSError(
                domain: "LibGit2WorktreeServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]
            )
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
