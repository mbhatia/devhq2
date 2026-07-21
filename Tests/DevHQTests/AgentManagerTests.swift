import Foundation
import XCTest
@testable import DevHQ

@MainActor
final class AgentManagerTests: XCTestCase {
    nonisolated func testSleepConversionClampsEveryFiniteTimingValueWithoutTrapping() {
        XCTAssertEqual(agentSleepNanoseconds(for: 0), nil)
        XCTAssertEqual(agentSleepNanoseconds(for: .nan), nil)
        XCTAssertEqual(agentSleepNanoseconds(for: 0.25), 250_000_000)
        XCTAssertEqual(
            agentSleepNanoseconds(for: .greatestFiniteMagnitude),
            86_400_000_000_000
        )
    }

    func testRestoreSanitizesAndDoesNotLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var changes: [[PersistedAgentState]] = []
        fixture.manager.onRecordsChanged = { _, states in changes.append(states) }

        fixture.manager.restore(
            [
                PersistedAgentState(profile: "codex", name: "  reviewer  ", needsInput: true, threadID: "thread-1"),
                PersistedAgentState(profile: "codex", name: "reviewer", needsInput: false, threadID: nil),
                PersistedAgentState(profile: " ", name: "invalid", needsInput: false, threadID: nil),
                PersistedAgentState(profile: "missing", name: "remembered", needsInput: false, threadID: nil)
            ],
            repository: fixture.repository,
            worktree: fixture.worktree
        )

        XCTAssertEqual(fixture.manager.records.map(\.name), ["reviewer", "remembered"])
        XCTAssertTrue(fixture.workspace.terminalSessions.isEmpty)
        XCTAssertEqual(changes.last?.count, 2)
    }

    func testRestoreRefreshesLiveRecordContextWithoutReplacingRuntimeState() throws {
        let fixture = try Fixture(profiles: [Self.profile(name: "test", start: "sleep 30")])
        defer { fixture.cleanUp() }
        let created = try fixture.manager.create(
            profile: "test",
            name: "reviewer",
            repository: fixture.repository,
            worktree: fixture.worktree
        )
        let terminal = try XCTUnwrap(fixture.manager.session(for: created.key))
        terminal.onAttention?()

        let refreshedWorktree = GitWorktreeInfo(
            name: "renamed-branch",
            url: fixture.worktree.url,
            isMain: true
        )
        let refreshedRepository = GitRepositoryInfo(
            rootURL: fixture.repository.rootURL,
            name: "renamed-repository",
            canonicalName: "renamed-repo-id",
            gitDirectoryURL: fixture.repository.gitDirectoryURL,
            worktrees: [refreshedWorktree]
        )
        fixture.manager.restore(
            [PersistedAgentState(
                profile: "test",
                name: "reviewer",
                needsInput: false,
                threadID: "stale-thread"
            )],
            repository: refreshedRepository,
            worktree: refreshedWorktree
        )

        let record = try XCTUnwrap(fixture.manager.record(for: created.key))
        XCTAssertEqual(record.context.repositoryName, "renamed-repo-id")
        XCTAssertEqual(record.context.worktreeName, "renamed-branch")
        XCTAssertTrue(record.needsInput, "Live attention state must win over stale persistence")
        XCTAssertNil(record.threadID, "Live thread state must win over stale persistence")
        XCTAssertEqual(fixture.manager.session(for: created.key)?.id, terminal.id)
    }

    func testCreateSuppliesEnvironmentNormalizesNameAndEnforcesScopedUniqueness() throws {
        let output = temporaryFileURL()
        let command = "printf '%s|%s|%s|%s|%s|%s' \"$PWD\" \"$REPO\" \"$REPO_ID\" \"$AGENT_PROFILE\" \"$AGENT_NAME\" \"$THREAD_ID\" > \(shellQuote(output.path)); sleep 30"
        let fixture = try Fixture(profiles: [Self.profile(name: "test", start: command)])
        defer { fixture.cleanUp() }

        let record = try fixture.manager.create(
            profile: "test",
            name: "  code reviewer  ",
            repository: fixture.repository,
            worktree: fixture.worktree
        )

        XCTAssertEqual(record.name, "code reviewer")
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: output.path) })
        XCTAssertEqual(
            try String(contentsOf: output),
            "\(fixture.worktree.url.path)|\(fixture.repository.rootURL.path)|repo-id|test|code-reviewer|"
        )
        XCTAssertThrowsError(try fixture.manager.create(
            profile: "test",
            name: "code reviewer",
            repository: fixture.repository,
            worktree: fixture.worktree
        )) { error in
            XCTAssertEqual(
                error as? AgentManagerError,
                .duplicateName(profile: "test", name: "code reviewer")
            )
        }
        fixture.manager.removeAgents(inWorktree: fixture.worktree.url)
    }

    func testRemoteAgentContextUsesRealRemoteRepositoryAndWorktreePaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let worktree = GitWorktreeInfo(
            name: "feature",
            url: directory.appendingPathComponent("mirror", isDirectory: true),
            isMain: false,
            remotePath: "/srv/repos/project.worktrees/feature"
        )
        let source = try SSHRemoteRepositorySource(
            server: "builder@example.com",
            remotePath: "/srv/repos/project"
        )
        let repository = GitRepositoryInfo(
            rootURL: directory,
            name: "project",
            canonicalName: "project@builder",
            gitDirectoryURL: directory.appendingPathComponent("mirror.git", isDirectory: true),
            worktrees: [worktree],
            remoteSource: source
        )
        let context = AgentWorktreeContext(repository: repository, worktree: worktree)

        XCTAssertEqual(context.remoteSource, source)
        XCTAssertEqual(context.remoteWorktreePath, "/srv/repos/project.worktrees/feature")
        XCTAssertEqual(
            AgentManager.launchEnvironment(
                profileName: "custom",
                name: "code reviewer",
                threadID: "thread-7",
                context: context
            ),
            [
                "REPO": "/srv/repos/project",
                "REPO_ID": "project@builder",
                "AGENT_PROFILE": "custom",
                "AGENT_NAME": "code-reviewer",
                "THREAD_ID": "thread-7"
            ]
        )
    }

    func testResumeCommandPrecedenceAndMissingResumeThread() throws {
        let output = temporaryFileURL()
        let commands = Self.profile(
            name: "test",
            start: "printf start > \(shellQuote(output.path)); sleep 30",
            resume: "printf resume > \(shellQuote(output.path)); sleep 30",
            resumeThread: "printf thread-$THREAD_ID > \(shellQuote(output.path)); sleep 30"
        )
        let fixture = try Fixture(profiles: [commands])
        defer { fixture.cleanUp() }
        fixture.manager.restore(
            [PersistedAgentState(profile: "test", name: "agent", needsInput: false, threadID: "abc")],
            repository: fixture.repository,
            worktree: fixture.worktree
        )
        let key = try XCTUnwrap(fixture.manager.records.first?.key)

        try fixture.manager.activate(key, repository: fixture.repository, worktree: fixture.worktree)
        XCTAssertTrue(waitUntil { (try? String(contentsOf: output)) == "thread-abc" })
        fixture.workspace.close(try XCTUnwrap(fixture.manager.session(for: key)))

        let noThreadResume = Self.profile(name: "other", start: "true", resume: "true")
        fixture.profiles.replace(with: [commands, noThreadResume])
        fixture.manager.restore(
            [PersistedAgentState(profile: "other", name: "agent", needsInput: false, threadID: "abc")],
            repository: fixture.repository,
            worktree: fixture.worktree
        )
        let missingKey = try XCTUnwrap(
            fixture.manager.records.first(where: { $0.profile == "other" })?.key
        )
        XCTAssertThrowsError(try fixture.manager.activate(
            missingKey,
            repository: fixture.repository,
            worktree: fixture.worktree
        )) { error in
            XCTAssertEqual(
                error as? AgentManagerError,
                .missingCommand(profile: "other", launchKind: "resume")
            )
        }
    }

    func testLiveActivationReusesTerminalAndAttentionAndExplicitCloseRetainsRecord() throws {
        let fixture = try Fixture(profiles: [Self.profile(name: "test", start: "sleep 30")])
        defer { fixture.cleanUp() }
        let record = try fixture.manager.create(
            profile: "test",
            name: "agent",
            repository: fixture.repository,
            worktree: fixture.worktree
        )
        let terminal = try XCTUnwrap(fixture.manager.session(for: record.key))

        terminal.onAttention?()
        XCTAssertTrue(fixture.manager.record(for: record.key)?.needsInput == true)
        try fixture.manager.activate(record.key, repository: fixture.repository, worktree: fixture.worktree)
        XCTAssertEqual(fixture.manager.session(for: record.key)?.id, terminal.id)
        XCTAssertFalse(fixture.manager.record(for: record.key)?.needsInput == true)

        terminal.onAttention?()
        terminal.onUserInput?()
        XCTAssertFalse(fixture.manager.record(for: record.key)?.needsInput == true)
        fixture.workspace.close(terminal)
        XCTAssertNotNil(fixture.manager.record(for: record.key))
        XCTAssertNil(fixture.manager.session(for: record.key))
    }

    func testNaturalExitRemovesRecordButShutdownAndRemovalHaveDistinctBehavior() throws {
        let fixture = try Fixture(profiles: [Self.profile(name: "test", start: "sleep 30")])
        defer { fixture.cleanUp() }
        let first = try fixture.manager.create(
            profile: "test", name: "first",
            repository: fixture.repository, worktree: fixture.worktree
        )
        let firstTerminal = try XCTUnwrap(fixture.manager.session(for: first.key))
        firstTerminal.onNaturalExit?(7)
        XCTAssertNil(fixture.manager.record(for: first.key))

        let second = try fixture.manager.create(
            profile: "test", name: "second",
            repository: fixture.repository, worktree: fixture.worktree
        )
        fixture.manager.prepareForTermination()
        fixture.workspace.closeAllTerminals()
        XCTAssertNotNil(fixture.manager.record(for: second.key))

        fixture.manager.removeAgents(in: fixture.repository)
        XCTAssertTrue(fixture.manager.records.isEmpty)
    }

    func testThreadCapturePersistsFirstNonemptyLuaCapture() throws {
        let matcher = StubPatternMatcher(results: [nil, "thread-42", "ignored"])
        let captureProfile = Self.profile(
            name: "test",
            start: "sleep 30",
            thread: AgentThreadConfiguration(
                input: "status $AGENT_PROFILE $AGENT_NAME $THREAD_ID\n",
                pattern: "Session:%s*(%S+)",
                delay: 0,
                submitDelay: 0,
                attempts: 3,
                interval: 0
            )
        )
        let fixture = try Fixture(
            profiles: [captureProfile],
            matcher: matcher,
            sleeper: { _ in await Task.yield() }
        )
        defer { fixture.cleanUp() }
        var persisted: [PersistedAgentState] = []
        fixture.manager.onRecordsChanged = { _, states in persisted = states }

        let record = try fixture.manager.create(
            profile: "test", name: "thread agent",
            repository: fixture.repository, worktree: fixture.worktree
        )
        XCTAssertTrue(waitUntil { fixture.manager.record(for: record.key)?.threadID == "thread-42" })
        XCTAssertEqual(persisted.first?.threadID, "thread-42")
        XCTAssertEqual(matcher.callCount, 2)
        fixture.manager.removeAgents(inWorktree: fixture.worktree.url)
    }

    private static func profile(
        name: String,
        start: String,
        resume: String? = nil,
        resumeThread: String? = nil,
        thread: AgentThreadConfiguration? = nil
    ) -> AgentProfile {
        AgentProfile(
            name: name,
            start: start,
            resume: resume,
            resumeThread: resumeThread,
            icon: nil,
            iconFont: .system,
            iconColor: nil,
            thread: thread
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
private final class StubPatternMatcher: LuaPatternMatching {
    private var results: [String?]
    private(set) var callCount = 0

    init(results: [String?] = [nil]) {
        self.results = results
    }

    func firstCapture(in text: String, pattern: String) throws -> String? {
        defer { callCount += 1 }
        return results.indices.contains(callCount) ? results[callCount] : nil
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let repository: GitRepositoryInfo
    let worktree: GitWorktreeInfo
    let workspace: WorkspaceModel
    let profiles: AgentProfileRegistry
    let manager: AgentManager

    init(
        profiles: [AgentProfile] = [AgentProfileDefaults.codex],
        matcher: LuaPatternMatching? = nil,
        sleeper: @escaping AgentManager.Sleeper = { interval in
            guard interval > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        worktree = GitWorktreeInfo(name: "main", url: directory, isMain: true)
        repository = GitRepositoryInfo(
            rootURL: directory,
            name: "repo",
            canonicalName: "repo-id",
            gitDirectoryURL: directory.appendingPathComponent(".git", isDirectory: true),
            worktrees: [worktree]
        )
        workspace = WorkspaceModel(arguments: ["DevHQ"])
        self.profiles = AgentProfileRegistry(profiles: profiles)
        manager = AgentManager(
            workspace: workspace,
            profiles: self.profiles,
            patternMatcher: matcher ?? StubPatternMatcher(),
            sleeper: sleeper
        )
    }

    func cleanUp() {
        manager.prepareForTermination()
        workspace.closeAllTerminals()
        try? FileManager.default.removeItem(at: directory)
    }
}
