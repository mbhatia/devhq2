import Foundation
import XCTest
@testable import DevHQ

@MainActor
final class AgentBuiltInCommandTests: XCTestCase {
    func testAgentCreateRequiresAConfiguredProfileAndTrackedWorktree() throws {
        let fixture = try Fixture(profiles: [])
        defer { fixture.cleanUp() }
        try fixture.register(prompt: AgentCreationPrompt { _ in nil })

        XCTAssertNotNil(fixture.commands.commandsByID["agent:create"])
        XCTAssertFalse(try fixture.availableCommandIDs().contains("agent:create"))

        fixture.profiles.replace(with: [Self.profile(name: "test")])
        XCTAssertFalse(try fixture.availableCommandIDs().contains("agent:create"))

        try fixture.trackAndSelectWorktree()
        XCTAssertTrue(try fixture.availableCommandIDs().contains("agent:create"))
    }

    func testAgentCreateOffersSortedProfilesAndCancellationIsANoOp() throws {
        let fixture = try Fixture(profiles: [
            Self.profile(name: "zeta"),
            Self.profile(name: "alpha")
        ])
        defer { fixture.cleanUp() }
        try fixture.trackAndSelectWorktree()
        var offeredProfiles: [String] = []
        try fixture.register(prompt: AgentCreationPrompt { profiles in
            offeredProfiles = profiles
            return nil
        })

        try fixture.commands.execute(id: "agent:create", in: fixture.context)

        XCTAssertEqual(offeredProfiles, ["alpha", "zeta"])
        XCTAssertTrue(fixture.agentManager.records.isEmpty)
        XCTAssertTrue(fixture.workspace.terminalSessions.isEmpty)
    }

    func testAgentCreateLaunchesAndSelectsTheAgentAndItsTerminal() throws {
        let fixture = try Fixture(profiles: [Self.profile(name: "test")])
        defer { fixture.cleanUp() }
        try fixture.trackAndSelectWorktree()
        try fixture.register(prompt: AgentCreationPrompt { _ in
            AgentCreationRequest(profile: "test", name: "reviewer")
        })

        try fixture.commands.execute(id: "agent:create", in: fixture.context)

        let record = try XCTUnwrap(fixture.agentManager.records.first)
        let terminal = try XCTUnwrap(fixture.agentManager.session(for: record.key))
        XCTAssertEqual(record.profile, "test")
        XCTAssertEqual(record.name, "reviewer")
        XCTAssertEqual(fixture.explorer.selectedAgentID, record.key)
        XCTAssertEqual(fixture.workspace.selectedTerminal?.id, terminal.id)
        XCTAssertTrue(fixture.explorer.tree.expandedIDs.contains(.worktree(fixture.worktree.id)))
    }

    func testAgentCreateReportsManagerErrorsThroughWorkspaceAlertState() throws {
        let fixture = try Fixture(profiles: [Self.profile(name: "test")])
        defer { fixture.cleanUp() }
        try fixture.trackAndSelectWorktree()
        _ = try fixture.agentManager.create(
            profile: "test",
            name: "duplicate",
            repository: fixture.repository,
            worktree: fixture.worktree
        )
        try fixture.register(prompt: AgentCreationPrompt { _ in
            AgentCreationRequest(profile: "test", name: " duplicate ")
        })

        XCTAssertNoThrow(
            try fixture.commands.execute(id: "agent:create", in: fixture.context)
        )
        XCTAssertEqual(
            fixture.workspace.errorMessage,
            AgentManagerError.duplicateName(profile: "test", name: "duplicate")
                .localizedDescription
        )
        XCTAssertEqual(fixture.agentManager.records.count, 1)
    }

    private static func profile(name: String) -> AgentProfile {
        AgentProfile(
            name: name,
            start: "sleep 30",
            resume: nil,
            resumeThread: nil,
            icon: nil,
            iconFont: .system,
            iconColor: nil,
            thread: nil
        )
    }
}

@MainActor
private final class Fixture {
    let parentDirectory: URL
    let repository: GitRepositoryInfo
    let worktree: GitWorktreeInfo
    let workspace: WorkspaceModel
    let profiles: AgentProfileRegistry
    let agentManager: AgentManager
    let explorer: WorktreeExplorerModel
    let commands = CommandManager()

    init(profiles: [AgentProfile]) throws {
        parentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parentDirectory.appendingPathComponent("repository", isDirectory: true)
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        worktree = GitWorktreeInfo(name: "main", url: root, isMain: true)
        repository = GitRepositoryInfo(
            rootURL: root,
            name: "repository",
            canonicalName: "repo-id",
            gitDirectoryURL: gitDirectory,
            worktrees: [worktree]
        )
        let workspace = WorkspaceModel(arguments: ["DevHQ"])
        self.workspace = workspace
        let profileRegistry = AgentProfileRegistry(profiles: profiles)
        self.profiles = profileRegistry
        let agentManager = AgentManager(
            workspace: workspace,
            profiles: profileRegistry,
            patternMatcher: AgentBuiltInCommandPatternMatcher()
        )
        self.agentManager = agentManager
        let discoverer = AgentBuiltInCommandDiscoverer(repository: repository)
        explorer = WorktreeExplorerModel(
            discoverer: discoverer,
            onActivate: { repository, worktree in
                workspace.openWorktree(
                    canonicalRepositoryName: repository.canonicalName,
                    worktreeName: worktree.name,
                    url: worktree.url
                )
            },
            agentManager: agentManager,
            onActivateAgent: { [agentManager] agent, repository, worktree in
                try agentManager.activate(
                    agent.key,
                    repository: repository,
                    worktree: worktree
                )
            },
            watcherFactory: { _, _ in AgentBuiltInCommandWatcher() },
            eventDelivery: { $0() }
        )
    }

    var context: CommandContext {
        CommandContext(view: .worktree, worktreeURL: workspace.rootURL)
    }

    func trackAndSelectWorktree() throws {
        try explorer.addRepository(repository.rootURL)
        let node = try XCTUnwrap(explorer.tree.roots.first?.children?.first)
        explorer.activate(node)
    }

    func register(prompt: AgentCreationPrompt) throws {
        try registerBuiltInCommands(
            in: commands,
            workspace: workspace,
            worktreeExplorer: explorer,
            pickers: BuiltInCommandPickers(
                repositoryURL: { nil },
                fileURL: { _ in nil },
                directoryURL: { _ in nil }
            ),
            agentManager: agentManager,
            agentProfiles: profiles,
            agentCreationPrompt: prompt
        )
    }

    func availableCommandIDs() throws -> [String] {
        try commands.commands(in: context).map(\.id)
    }

    func cleanUp() {
        agentManager.removeAgents(in: repository)
        workspace.closeAllTerminals()
        try? FileManager.default.removeItem(at: parentDirectory)
    }
}

@MainActor
private final class AgentBuiltInCommandPatternMatcher: LuaPatternMatching {
    func firstCapture(in text: String, pattern: String) throws -> String? { nil }
}

private final class AgentBuiltInCommandDiscoverer: GitWorktreeDiscovering {
    let repository: GitRepositoryInfo

    init(repository: GitRepositoryInfo) {
        self.repository = repository
    }

    func discover(at url: URL) throws -> GitRepositoryInfo { repository }
}

private final class AgentBuiltInCommandWatcher: RepositoryWatching {
    func cancel() {}
}
