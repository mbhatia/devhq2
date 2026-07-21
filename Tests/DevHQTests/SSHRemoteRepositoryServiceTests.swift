import Foundation
import XCTest
@testable import DevHQ

final class SSHRemoteRepositoryServiceTests: XCTestCase {
    func testParsesSourceAndBuildsDeterministicMirrorPath() throws {
        let root = URL(fileURLWithPath: "/tmp/remote-mirrors", isDirectory: true)
        let service = SSHRemoteRepositoryService(
            commandRunner: ScriptedSSHRemoteRunner(gitDirectory: root),
            mirrorRootURL: root
        )

        let source = try service.parseSource("  git@example.com:/srv/repos/devhq  ")

        XCTAssertEqual(source.server, "git@example.com")
        XCTAssertEqual(source.remotePath, "/srv/repos/devhq")
        XCTAssertEqual(source.repositoryName, "devhq")
        XCTAssertEqual(
            service.mirrorPath(for: source).path,
            "/tmp/remote-mirrors/git@example.com/srv/repos/devhq"
        )
        XCTAssertEqual(
            SSHRemoteRepositoryService.defaultMirrorRootURL.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/devhq/remote-mirrors").path
        )
    }

    func testRejectsInvalidSourceComponents() {
        let service = SSHRemoteRepositoryService(
            commandRunner: ScriptedSSHRemoteRunner(gitDirectory: URL(fileURLWithPath: "/tmp"))
        )
        for value in ["", "host", ":/repo", "bad host:/repo", "-oProxy:/repo", "host:   ", "host:/repo\nother"] {
            XCTAssertThrowsError(try service.parseSource(value), value)
        }
    }

    func testSynchronizesOnlyNamedWorktreeWithBoundedDetachedHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = String(repeating: "a", count: 40)
        let base = String(repeating: "b", count: 40)
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.gitDirectory,
            remoteHead: head,
            mergeBase: base
        )
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot
        )
        let source = try service.parseSource("build.example:/srv/devhq")

        let snapshot = try await service.synchronize(source)

        XCTAssertEqual(snapshot.worktrees.count, 1)
        XCTAssertEqual(snapshot.worktrees.first?.name, "feature")
        XCTAssertEqual(snapshot.worktrees.first?.remotePath, "/srv/devhq")
        XCTAssertEqual(snapshot.worktrees.first?.localURL, snapshot.rootURL)
        XCTAssertEqual(snapshot.worktrees.first?.isMain, true)
        XCTAssertEqual(snapshot.worktrees.first?.head, head)
        XCTAssertEqual(
            try String(contentsOf: fixture.gitDirectory.appendingPathComponent("devhq-parent-ref")),
            base + "\n"
        )

        let commands = await runner.invocations()
        XCTAssertTrue(commands.containsGitArguments([
            "clone", "--depth=1", "--no-tags", "--no-checkout",
            "build.example:/srv/devhq", snapshot.rootURL.path
        ]))
        XCTAssertTrue(commands.containsGitSuffix([
            "fetch", "--force", "--no-tags", "--depth=3", "build.example",
            "+refs/heads/feature:refs/remotes/build.example/feature"
        ]))
        XCTAssertTrue(commands.containsGitSuffix([
            "checkout", "-f", "--detach", "refs/remotes/build.example/feature"
        ]))
        XCTAssertFalse(commands.contains { $0.arguments.contains("ignored") })
        XCTAssertFalse(commands.contains { $0.arguments.contains("prunable") })
    }

    func testRejectsSnapshotWhenFetchedBranchDiffersFromInspectedHead() async throws {
        let fixture = try Fixture(existingMirror: true)
        defer { fixture.remove() }
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.gitDirectory,
            remoteHead: String(repeating: "a", count: 40),
            fetchedHead: String(repeating: "c", count: 40)
        )
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot
        )

        do {
            try await service.synchronize(service.parseSource("build.example:/srv/devhq"))
            XCTFail("Expected a race failure")
        } catch let error as SSHRemoteRepositoryError {
            XCTAssertEqual(error, .branchChanged("feature"))
        }
        let commands = await runner.invocations()
        XCTAssertFalse(commands.contains { invocation in
            invocation.arguments.contains("checkout")
                || invocation.arguments.contains("worktree") && invocation.arguments.contains("remove")
        })
    }

    func testRejectsManagedCheckoutWhoseGitMetadataEscapesMirrorRoot() async throws {
        let fixture = try Fixture(existingMirror: true)
        defer { fixture.remove() }
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.directory.appendingPathComponent("outside-git")
        )
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot
        )

        do {
            try await service.synchronize(service.parseSource("build.example:/srv/devhq"))
            XCTFail("Expected repository metadata containment failure")
        } catch let error as SSHRemoteRepositoryError {
            guard case .unsafeManagedPath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let commands = await runner.invocations()
        XCTAssertFalse(commands.contains { invocation in
            invocation.arguments.contains("fetch")
                || invocation.arguments.contains("update-ref")
                || invocation.arguments.contains("clean")
        })
    }

    func testRefusesToRemoveStaleWorktreeOutsideManagedRoot() async throws {
        let fixture = try Fixture(existingMirror: true)
        defer { fixture.remove() }
        let outside = URL(fileURLWithPath: "/tmp/not-a-devhq-mirror")
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.gitDirectory,
            localWorktreeOutput: "worktree \(fixture.mirrorPath.path)\nHEAD deadbeef\ndetached\n\nworktree \(outside.path)\nHEAD deadbeef\ndetached\n"
        )
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot
        )

        do {
            try await service.synchronize(service.parseSource("build.example:/srv/devhq"))
            XCTFail("Expected the destructive-path guard")
        } catch let error as SSHRemoteRepositoryError {
            guard case .unsafeManagedPath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLateWantedCheckoutFailureLeavesStaleWorktreeRegistered() async throws {
        let fixture = try Fixture(existingMirror: true)
        defer { fixture.remove() }
        let stale = fixture.mirrorRoot.appendingPathComponent("build.example/srv/stale")
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.gitDirectory,
            localWorktreeOutput: "worktree \(fixture.mirrorPath.path)\nHEAD deadbeef\ndetached\n\nworktree \(stale.path)\nHEAD deadbeef\ndetached\n",
            failingGitSuffix: [
                "reset", "--hard", "refs/remotes/build.example/feature"
            ]
        )
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot
        )

        do {
            try await service.synchronize(service.parseSource("build.example:/srv/devhq"))
            XCTFail("Expected the wanted checkout to fail")
        } catch let error as SSHRemoteRepositoryError {
            guard case .commandFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let commands = await runner.invocations()
        XCTAssertFalse(commands.containsGitSuffix([
            "worktree", "remove", "--force", stale.path
        ]))
        XCTAssertFalse(commands.containsGitSuffix(["worktree", "prune"]))
    }

    func testLaterStaleCleanupFailureStillReturnsCoherentSnapshot() async throws {
        let fixture = try Fixture(existingMirror: true)
        defer { fixture.remove() }
        let firstStale = fixture.mirrorRoot.appendingPathComponent("build.example/srv/01-stale")
        let secondStale = fixture.mirrorRoot.appendingPathComponent("build.example/srv/02-stale")
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.gitDirectory,
            localWorktreeOutput: """
                worktree \(fixture.mirrorPath.path)
                HEAD deadbeef
                detached

                worktree \(firstStale.path)
                HEAD deadbeef
                detached

                worktree \(secondStale.path)
                HEAD deadbeef
                detached
                """,
            failingGitSuffix: ["worktree", "remove", "--force", secondStale.path]
        )
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot
        )

        let snapshot = try await service.synchronize(
            service.parseSource("build.example:/srv/devhq")
        )

        XCTAssertEqual(snapshot.worktrees.map(\.name), ["feature"])
        XCTAssertEqual(snapshot.cleanupWarnings.count, 1)
        XCTAssertTrue(snapshot.cleanupWarnings[0].contains(secondStale.path))
        XCTAssertTrue(snapshot.cleanupWarnings[0].contains("injected checkout failure"))
        let commands = await runner.invocations()
        XCTAssertTrue(commands.containsGitSuffix([
            "worktree", "remove", "--force", firstStale.path
        ]))
        XCTAssertTrue(commands.containsGitSuffix([
            "worktree", "remove", "--force", secondStale.path
        ]))
        XCTAssertTrue(commands.containsGitSuffix(["worktree", "prune"]))
    }

    func testMutationProtectionCanDeferAfterFetchBeforeLocalCheckoutChanges() async throws {
        let fixture = try Fixture(existingMirror: true)
        defer { fixture.remove() }
        let stale = fixture.mirrorRoot.appendingPathComponent("build.example/srv/stale")
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.gitDirectory,
            localWorktreeOutput: "worktree \(fixture.mirrorPath.path)\nHEAD deadbeef\ndetached\n\nworktree \(stale.path)\nHEAD deadbeef\ndetached\n"
        )
        let capture = MutationProtectionCapture()
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot,
            mutationProtection: { _, urls in
                await capture.record(urls)
                let commands = await runner.invocations()
                return !commands.containsGitSuffix([
                    "fetch", "--force", "--no-tags", "--depth=1", "build.example",
                    "+refs/heads/feature:refs/remotes/build.example/feature"
                ])
            }
        )

        do {
            try await service.synchronize(service.parseSource("build.example:/srv/devhq"))
            XCTFail("Expected mutation protection to defer the refresh")
        } catch let error as SSHRemoteRepositoryError {
            XCTAssertEqual(error, .localMutationProtected)
        }

        let protectedURLs = await capture.urls()
        XCTAssertEqual(protectedURLs, Set([fixture.mirrorPath, stale]))
        let commands = await runner.invocations()
        XCTAssertTrue(commands.contains { $0.arguments.contains("fetch") })
        XCTAssertTrue(commands.containsGitSuffix([
            "rev-parse", "--verify", "refs/remotes/build.example/feature"
        ]))
        XCTAssertFalse(commands.contains { invocation in
            invocation.arguments.contains("clean")
                || invocation.arguments.contains("checkout")
                || invocation.arguments.contains("reset")
                || invocation.arguments.contains("worktree") && invocation.arguments.contains("add")
                || invocation.arguments.contains("worktree") && invocation.arguments.contains("remove")
        })
    }

    func testMutationProtectionIsRecheckedBeforeWantedCheckoutMutation() async throws {
        let fixture = try Fixture(existingMirror: true)
        defer { fixture.remove() }
        let runner = ScriptedSSHRemoteRunner(gitDirectory: fixture.gitDirectory)
        let gate = SequencedMutationProtection(allowedCalls: 1)
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot,
            mutationProtection: { _, _ in await gate.allow() }
        )

        do {
            try await service.synchronize(service.parseSource("build.example:/srv/devhq"))
            XCTFail("Expected protection to change before checkout mutation")
        } catch let error as SSHRemoteRepositoryError {
            XCTAssertEqual(error, .localMutationProtected)
        }

        let protectionChecks = await gate.callCount()
        XCTAssertEqual(protectionChecks, 2)
        let commands = await runner.invocations()
        XCTAssertFalse(commands.contains { invocation in
            invocation.arguments.contains("clean")
                || invocation.arguments.contains("checkout")
                || invocation.arguments.contains("reset")
        })
    }

    func testProtectionDenialSkipsStaleRemovalAndReturnsWarning() async throws {
        let fixture = try Fixture(existingMirror: true)
        defer { fixture.remove() }
        let stale = fixture.mirrorRoot.appendingPathComponent("build.example/srv/stale")
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.gitDirectory,
            localWorktreeOutput: "worktree \(fixture.mirrorPath.path)\nHEAD deadbeef\ndetached\n\nworktree \(stale.path)\nHEAD deadbeef\ndetached\n"
        )
        // Initial preflight plus four checks around clean/checkout/reset/clean.
        let gate = SequencedMutationProtection(allowedCalls: 5)
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot,
            mutationProtection: { _, _ in await gate.allow() }
        )

        let snapshot = try await service.synchronize(
            service.parseSource("build.example:/srv/devhq")
        )

        XCTAssertEqual(snapshot.worktrees.map(\.name), ["feature"])
        XCTAssertEqual(snapshot.cleanupWarnings.count, 1)
        XCTAssertTrue(snapshot.cleanupWarnings[0].contains(stale.path))
        XCTAssertTrue(snapshot.cleanupWarnings[0].contains("protected"))
        let commands = await runner.invocations()
        XCTAssertFalse(commands.containsGitSuffix([
            "worktree", "remove", "--force", stale.path
        ]))
        XCTAssertFalse(commands.containsGitSuffix(["worktree", "prune"]))
    }

    func testFreshCloneSeedsMatchingBranchWithoutSecondFetch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = String(repeating: "a", count: 40)
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.gitDirectory,
            remoteHead: head,
            cloneOriginHead: head
        )
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot
        )

        let snapshot = try await service.synchronize(
            service.parseSource("build.example:/srv/devhq")
        )

        XCTAssertEqual(snapshot.worktrees.map(\.head), [head])
        let commands = await runner.invocations()
        XCTAssertFalse(commands.contains { $0.executable == "git" && $0.arguments.contains("fetch") })
        XCTAssertTrue(commands.containsGitSuffix([
            "update-ref", "refs/remotes/build.example/feature", head
        ]))
    }

    func testFreshCloneWithMismatchedBranchAttemptsBoundedFetchAndPropagatesFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = String(repeating: "a", count: 40)
        let fetch = [
            "fetch", "--force", "--no-tags", "--depth=1", "build.example",
            "+refs/heads/feature:refs/remotes/build.example/feature"
        ]
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.gitDirectory,
            remoteHead: head,
            cloneOriginHead: String(repeating: "c", count: 40),
            failingGitSuffix: fetch
        )
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot
        )

        do {
            try await service.synchronize(service.parseSource("build.example:/srv/devhq"))
            XCTFail("Expected the required fetch failure")
        } catch let error as SSHRemoteRepositoryError {
            guard case .commandFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let commands = await runner.invocations()
        XCTAssertTrue(commands.containsGitSuffix(fetch))
    }

    func testFreshCloneMissingRequiredHistoryAttemptsBoundedFetch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = String(repeating: "a", count: 40)
        let base = String(repeating: "b", count: 40)
        let fetch = [
            "fetch", "--force", "--no-tags", "--depth=3", "build.example",
            "+refs/heads/feature:refs/remotes/build.example/feature"
        ]
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.gitDirectory,
            remoteHead: head,
            mergeBase: base,
            cloneOriginHead: head,
            hasLocalRequiredHistory: false,
            failingGitSuffix: fetch
        )
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot
        )

        do {
            try await service.synchronize(service.parseSource("build.example:/srv/devhq"))
            XCTFail("Expected the history fetch failure")
        } catch let error as SSHRemoteRepositoryError {
            guard case .commandFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let commands = await runner.invocations()
        XCTAssertTrue(commands.containsGitSuffix(fetch))
    }

    func testEligibleExistingMirrorReusesExactCloneReferenceWithoutFetch() async throws {
        let fixture = try Fixture(existingMirror: true)
        defer { fixture.remove() }
        let head = String(repeating: "a", count: 40)
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.gitDirectory,
            remoteHead: head,
            cloneOriginHead: head
        )
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot
        )

        let snapshot = try await service.synchronize(
            service.parseSource("build.example:/srv/devhq"),
            context: SSHRemoteSynchronizationContext(allowExistingCloneReferenceReuse: true)
        )

        XCTAssertEqual(snapshot.worktrees.map(\.head), [head])
        let commands = await runner.invocations()
        XCTAssertFalse(commands.contains { $0.executable == "git" && $0.arguments.contains("clone") })
        XCTAssertFalse(commands.contains { $0.executable == "git" && $0.arguments.contains("fetch") })
        XCTAssertTrue(commands.containsGitSuffix([
            "update-ref", "refs/remotes/build.example/feature", head
        ]))
    }

    func testNormalExistingMirrorStillUsesBoundedFetch() async throws {
        let fixture = try Fixture(existingMirror: true)
        defer { fixture.remove() }
        let head = String(repeating: "a", count: 40)
        let fetch = [
            "fetch", "--force", "--no-tags", "--depth=1", "build.example",
            "+refs/heads/feature:refs/remotes/build.example/feature"
        ]
        let runner = ScriptedSSHRemoteRunner(
            gitDirectory: fixture.gitDirectory,
            remoteHead: head,
            cloneOriginHead: head,
            failingGitSuffix: fetch
        )
        let service = SSHRemoteRepositoryService(
            commandRunner: runner,
            mirrorRootURL: fixture.mirrorRoot
        )

        do {
            try await service.synchronize(service.parseSource("build.example:/srv/devhq"))
            XCTFail("Expected normal synchronization to perform the bounded fetch")
        } catch let error as SSHRemoteRepositoryError {
            guard case .commandFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let commands = await runner.invocations()
        XCTAssertTrue(commands.containsGitSuffix(fetch))
        XCTAssertFalse(commands.containsGitSuffix([
            "update-ref", "refs/remotes/build.example/feature", head
        ]))
    }
}

private struct RemoteCommandInvocation: Sendable {
    let executable: String
    let arguments: [String]
}

private actor MutationProtectionCapture {
    private var capturedURLs = Set<URL>()

    func record(_ urls: Set<URL>) { capturedURLs = urls }
    func urls() -> Set<URL> { capturedURLs }
}

private actor SequencedMutationProtection {
    private let allowedCalls: Int
    private var calls = 0

    init(allowedCalls: Int) { self.allowedCalls = allowedCalls }

    func allow() -> Bool {
        calls += 1
        return calls <= allowedCalls
    }

    func callCount() -> Int { calls }
}

private actor ScriptedSSHRemoteRunner: SSHRemoteCommandRunning {
    private var commands = [RemoteCommandInvocation]()
    private let gitDirectory: URL
    private let remoteHead: String
    private let fetchedHead: String
    private let mergeBase: String?
    private let localWorktreeOutput: String?
    private let cloneOriginHead: String?
    private let hasLocalRequiredHistory: Bool
    private let failingGitSuffix: [String]?

    init(
        gitDirectory: URL,
        remoteHead: String = String(repeating: "a", count: 40),
        fetchedHead: String? = nil,
        mergeBase: String? = nil,
        localWorktreeOutput: String? = nil,
        cloneOriginHead: String? = nil,
        hasLocalRequiredHistory: Bool = true,
        failingGitSuffix: [String]? = nil
    ) {
        self.gitDirectory = gitDirectory
        self.remoteHead = remoteHead
        self.fetchedHead = fetchedHead ?? remoteHead
        self.mergeBase = mergeBase
        self.localWorktreeOutput = localWorktreeOutput
        self.cloneOriginHead = cloneOriginHead
        self.hasLocalRequiredHistory = hasLocalRequiredHistory
        self.failingGitSuffix = failingGitSuffix
    }

    func invocations() -> [RemoteCommandInvocation] { commands }

    func run(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL?
    ) async throws -> SSHRemoteCommandResult {
        commands.append(RemoteCommandInvocation(executable: executable, arguments: arguments))
        if executable == "ssh" {
            let script = arguments.last ?? ""
            if script.contains("remote"), script.contains("-v") {
                return .init(standardOutput: "origin git@example/repo (fetch)\norigin git@example/repo (push)\n")
            }
            if script.contains("for-each-ref") {
                return .init(standardOutput: "feature\torigin/main\n")
            }
            if script.contains("worktree"), script.contains("--porcelain") {
                return .init(standardOutput: """
                    worktree /srv/devhq
                    HEAD \(remoteHead)
                    branch refs/heads/feature

                    worktree /srv/detached
                    HEAD \(remoteHead)
                    detached

                    worktree /srv/ignored
                    HEAD \(remoteHead)
                    branch refs/heads/ignored
                    bare

                    worktree /srv/prunable
                    HEAD \(remoteHead)
                    branch refs/heads/prunable
                    prunable stale metadata
                    """)
            }
            if script.contains("merge-base") {
                return mergeBase.map { .init(standardOutput: $0 + "\n") }
                    ?? .init(standardError: "no merge base", exitCode: 1)
            }
            if script.contains("rev-list"), script.contains("--count") {
                return .init(standardOutput: "login noise\n2\n")
            }
            return .init()
        }

        if arguments.contains("clone") {
            if let path = arguments.last {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: path).appendingPathComponent(".git"),
                    withIntermediateDirectories: true
                )
            }
            return .init()
        }
        if let failingGitSuffix,
           arguments.suffix(failingGitSuffix.count).elementsEqual(failingGitSuffix) {
            return .init(standardError: "injected checkout failure", exitCode: 7)
        }
        if arguments.suffix(3).elementsEqual(["remote", "get-url", "build.example"]) {
            return .init(exitCode: 2)
        }
        if arguments.suffix(3).elementsEqual(["worktree", "list", "--porcelain"]) {
            if let localWorktreeOutput { return .init(standardOutput: localWorktreeOutput) }
            let root = arguments[1]
            return .init(standardOutput: "worktree \(root)\nHEAD \(remoteHead)\ndetached\n")
        }
        if arguments.contains("rev-parse"), arguments.contains("--verify") {
            if arguments.last?.hasPrefix("refs/remotes/origin/") == true {
                return cloneOriginHead.map { .init(standardOutput: $0 + "\n") }
                    ?? .init(standardError: "clone branch unavailable", exitCode: 1)
            }
            return .init(standardOutput: fetchedHead + "\n")
        }
        if arguments.contains("merge-base") {
            guard hasLocalRequiredHistory else {
                return .init(standardError: "shallow history", exitCode: 1)
            }
            return .init(standardOutput: (mergeBase ?? "") + "\n")
        }
        if arguments.suffix(2).elementsEqual(["--path-format=absolute", "--git-dir"])
            || arguments.suffix(2).elementsEqual(["--path-format=absolute", "--git-common-dir"]) {
            return .init(standardOutput: gitDirectory.path + "\n")
        }
        return .init()
    }
}

private struct Fixture {
    let directory: URL
    let mirrorRoot: URL
    let mirrorPath: URL
    let gitDirectory: URL

    init(existingMirror: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHRemoteRepositoryServiceTests-\(UUID().uuidString)", isDirectory: true)
        mirrorRoot = directory.appendingPathComponent("remote-mirrors", isDirectory: true)
        mirrorPath = mirrorRoot
            .appendingPathComponent("build.example/srv/devhq", isDirectory: true)
        gitDirectory = mirrorPath.appendingPathComponent(".git", isDirectory: true)
        if existingMirror {
            try FileManager.default.createDirectory(
                at: gitDirectory,
                withIntermediateDirectories: true
            )
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private extension Array where Element == RemoteCommandInvocation {
    func containsGitArguments(_ expected: [String]) -> Bool {
        contains { $0.executable == "git" && $0.arguments == expected }
    }

    func containsGitSuffix(_ expected: [String]) -> Bool {
        contains { $0.executable == "git" && $0.arguments.suffix(expected.count).elementsEqual(expected) }
    }
}
