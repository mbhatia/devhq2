import Foundation
import XCTest
@testable import DevHQ

final class RepositoryWatcherNestedMetadataTests: XCTestCase {
    func testObservesHeadChangeInsideExistingWorktreeMetadataDirectory() throws {
        let gitDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let metadataDirectory = gitDirectory
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("feature", isDirectory: true)
        let headURL = metadataDirectory.appendingPathComponent("HEAD")
        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true
        )
        try "ref: refs/heads/main\n".write(to: headURL, atomically: false, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: gitDirectory) }

        let changed = expectation(description: "Linked worktree HEAD changed")
        changed.assertForOverFulfill = false
        let watcher = try RepositoryWatcher(
            gitDirectoryURL: gitDirectory,
            debounceInterval: .milliseconds(10)
        ) {
            changed.fulfill()
        }
        defer { watcher.cancel() }

        try "ref: refs/heads/feature/new-name\n".write(
            to: headURL,
            atomically: false,
            encoding: .utf8
        )

        wait(for: [changed], timeout: 2)
    }
}
