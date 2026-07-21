import Foundation
import XCTest
@testable import DevHQ

final class GitQueryServiceTests: XCTestCase {
    func testUncommittedAndStagedChangesHaveStatusAndCounts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        try "staged\n".write(
            to: fixture.repository.appendingPathComponent("staged.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "staged.txt"], in: fixture.repository)
        try "base\nchanged\n".write(
            to: fixture.repository.appendingPathComponent("base.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: fixture.repository.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )
        try "new\n".write(
            to: fixture.repository.appendingPathComponent("nested/untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let service = GitQueryService()
        let uncommitted = try await service.changes(
            in: fixture.repository,
            mode: .uncommitted,
            forceRefresh: true
        )
        let staged = try await service.changes(
            in: fixture.repository,
            mode: .staged,
            forceRefresh: true
        )

        XCTAssertEqual(Set(uncommitted.changes.map(\.path)), [
            "base.txt", "staged.txt", "nested/untracked.txt"
        ])
        XCTAssertEqual(uncommitted.changes.first { $0.path == "base.txt" }?.kind, .modified)
        XCTAssertEqual(uncommitted.changes.first { $0.path == "base.txt" }?.additions, 1)
        XCTAssertEqual(uncommitted.changes.first { $0.path == "staged.txt" }?.kind, .added)
        XCTAssertEqual(uncommitted.changes.first { $0.path == "nested/untracked.txt" }?.kind, .untracked)
        XCTAssertEqual(staged.changes.map(\.path), ["staged.txt"])
        XCTAssertEqual(staged.changes.first?.additions, 1)
        XCTAssertEqual(staged.changes.first?.deletions, 0)
    }

    func testHeadUsesConventionalDefaultBranchMergeBase() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try git(["checkout", "-b", "feature"], in: fixture.repository)
        try "feature\n".write(
            to: fixture.repository.appendingPathComponent("feature.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "feature.txt"], in: fixture.repository)
        try commit("feature", in: fixture.repository)

        let snapshot = try await GitQueryService().changes(
            in: fixture.repository,
            mode: .head,
            forceRefresh: true
        )

        XCTAssertEqual(snapshot.changes.map(\.path), ["feature.txt"])
        XCTAssertEqual(snapshot.changes.first?.kind, .added)
        guard case let .resolved(reference, mergeBase) = snapshot.parentState else {
            return XCTFail("Expected a resolved default branch parent")
        }
        XCTAssertEqual(reference, "main")
        XCTAssertEqual(mergeBase, fixture.baseCommit)
    }

    func testStagedRenameRetainsOldAndNewPaths() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try git(["mv", "base.txt", "renamed.txt"], in: fixture.repository)

        let snapshot = try await GitQueryService().changes(
            in: fixture.repository,
            mode: .staged,
            forceRefresh: true
        )

        XCTAssertEqual(snapshot.changes.count, 1)
        XCTAssertEqual(snapshot.changes.first?.kind, .renamed)
        XCTAssertEqual(snapshot.changes.first?.oldPath, "base.txt")
        XCTAssertEqual(snapshot.changes.first?.path, "renamed.txt")
        XCTAssertEqual(snapshot.changes.first?.additions, 0)
        XCTAssertEqual(snapshot.changes.first?.deletions, 0)
    }

    func testForceRefreshBypassesBriefCache() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let service = GitQueryService(cacheTTL: 60)
        let first = try await service.changes(
            in: fixture.repository,
            mode: .uncommitted,
            forceRefresh: false
        )
        try "new\n".write(
            to: fixture.repository.appendingPathComponent("later.txt"),
            atomically: true,
            encoding: .utf8
        )

        let cached = try await service.changes(
            in: fixture.repository,
            mode: .uncommitted,
            forceRefresh: false
        )
        let refreshed = try await service.changes(
            in: fixture.repository,
            mode: .uncommitted,
            forceRefresh: true
        )

        XCTAssertEqual(first.contextID, cached.contextID)
        XCTAssertTrue(cached.changes.isEmpty)
        XCTAssertEqual(refreshed.changes.map(\.path), ["later.txt"])
        XCTAssertNotEqual(first.contextID, refreshed.contextID)
    }

    func testUnrelatedConventionalBranchProducesNoParent() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try git(["checkout", "--orphan", "unrelated"], in: fixture.repository)
        try git(["rm", "-rf", "."], in: fixture.repository)
        try "orphan\n".write(
            to: fixture.repository.appendingPathComponent("orphan.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "orphan.txt"], in: fixture.repository)
        try commit("orphan", in: fixture.repository)

        let snapshot = try await GitQueryService().changes(
            in: fixture.repository,
            mode: .head,
            forceRefresh: true
        )

        XCTAssertTrue(snapshot.changes.isEmpty)
        guard case let .noParent(message) = snapshot.parentState else {
            return XCTFail("Expected a visible no-parent state")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testDeletedFileContentUsesModeBaseline() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.removeItem(at: fixture.repository.appendingPathComponent("base.txt"))
        let service = GitQueryService()

        let uncommitted = try await service.fileContent(
            in: fixture.repository,
            path: "base.txt",
            mode: .uncommitted
        )
        try git(["add", "-u"], in: fixture.repository)
        let staged = try await service.fileContent(
            in: fixture.repository,
            path: "base.txt",
            mode: .staged
        )

        XCTAssertEqual(String(decoding: uncommitted, as: UTF8.self), "base\n")
        XCTAssertEqual(String(decoding: staged, as: UTF8.self), "base\n")
    }

    func testHeadAndFullContentUseDefaultBranchMergeBase() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try git(["checkout", "-b", "feature"], in: fixture.repository)
        try "feature\n".write(
            to: fixture.repository.appendingPathComponent("base.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "base.txt"], in: fixture.repository)
        try commit("feature", in: fixture.repository)
        let service = GitQueryService()

        let head = try await service.fileContent(
            in: fixture.repository,
            path: "base.txt",
            mode: .head
        )
        let full = try await service.fileContent(
            in: fixture.repository,
            path: "base.txt",
            mode: .full
        )

        XCTAssertEqual(String(decoding: head, as: UTF8.self), "base\n")
        XCTAssertEqual(full, head)
    }

    func testUnbornHeadUsesEmptyTreeSemantics() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try gitRaw(["init", "-b", "main", repository.path])
        try "staged\n".write(
            to: repository.appendingPathComponent("staged.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "staged.txt"], in: repository)
        try "untracked\n".write(
            to: repository.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        let service = GitQueryService()

        let staged = try await service.changes(
            in: repository,
            mode: .staged,
            forceRefresh: true
        )
        let uncommitted = try await service.changes(
            in: repository,
            mode: .uncommitted,
            forceRefresh: true
        )

        XCTAssertEqual(staged.changes.map(\.path), ["staged.txt"])
        XCTAssertEqual(staged.changes.first?.kind, .added)
        XCTAssertEqual(Set(uncommitted.changes.map(\.path)), ["staged.txt", "untracked.txt"])
        XCTAssertEqual(uncommitted.changes.first { $0.path == "staged.txt" }?.kind, .added)
        XCTAssertEqual(uncommitted.changes.first { $0.path == "untracked.txt" }?.kind, .untracked)
    }

    func testFileContentReportsNoParentForUnbornHead() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try gitRaw(["init", "-b", "main", repository.path])

        do {
            _ = try await GitQueryService().fileContent(
                in: repository,
                path: "missing.txt",
                mode: .uncommitted
            )
            XCTFail("Expected no-parent error")
        } catch let GitQueryError.noParent(message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private struct Fixture {
        let container: URL
        let repository: URL
        let baseCommit: String
    }

    private func makeFixture() throws -> Fixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try gitRaw(["init", "-b", "main", repository.path])
        try git(["config", "user.email", "devhq@example.invalid"], in: repository)
        try git(["config", "user.name", "DevHQ Tests"], in: repository)
        try "base\n".write(
            to: repository.appendingPathComponent("base.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "base.txt"], in: repository)
        try commit("base", in: repository)
        let baseCommit = try gitOutput(["rev-parse", "HEAD"], in: repository)
        return Fixture(container: container, repository: repository, baseCommit: baseCommit)
    }

    private func commit(_ message: String, in repository: URL) throws {
        try git(["commit", "-m", message, "--no-gpg-sign"], in: repository)
    }

    private func git(_ arguments: [String], in repository: URL) throws {
        try gitRaw(["-C", repository.path] + arguments)
    }

    private func gitOutput(_ arguments: [String], in repository: URL) throws -> String {
        try gitRaw(["-C", repository.path] + arguments, captureOutput: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func gitRaw(_ arguments: [String], captureOutput: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GitQueryError.commandFailed(arguments: arguments, message: text)
        }
        return captureOutput ? text : ""
    }
}
