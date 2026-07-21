import Foundation
import XCTest
@testable import DevHQ

final class AgentPersistenceTests: XCTestCase {
    func testLegacyWorktreeStateDecodesWithNoAgents() throws {
        let data = Data(
            #"{"branchName":"main","path":"/repos/devhq","isMain":true,"isExpanded":false,"isSelected":true}"#.utf8
        )

        let state = try JSONDecoder().decode(PersistedWorktreeState.self, from: data)

        XCTAssertEqual(state.agents, [])
    }

    func testWorktreeAgentStateRoundTripsUsingStableFieldNames() throws {
        let state = PersistedWorktreeState(
            branchName: "feature/agents",
            path: "/repos/devhq/.worktrees/feature-agents",
            isMain: false,
            isExpanded: true,
            isSelected: false,
            agents: [
                PersistedAgentState(
                    profile: "codex",
                    name: "reviewer",
                    needsInput: true,
                    threadID: "thread-123"
                ),
                PersistedAgentState(
                    profile: "shell",
                    name: "build",
                    needsInput: false,
                    threadID: nil
                )
            ]
        )

        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let agents = try XCTUnwrap(object["agents"] as? [[String: Any]])

        XCTAssertEqual(agents.count, 2)
        XCTAssertEqual(Set(agents[0].keys), ["profile", "name", "needs_input", "thread_id"])
        XCTAssertEqual(Set(agents[1].keys), ["profile", "name", "needs_input"])
        XCTAssertNil(agents[0]["needsInput"])
        XCTAssertNil(agents[0]["threadID"])
        XCTAssertEqual(try JSONDecoder().decode(PersistedWorktreeState.self, from: data), state)
    }

    func testAgentIdentityUsesCanonicalWorktreePathProfileAndTrimmedRawName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let realWorktree = root.appendingPathComponent("worktree", isDirectory: true)
        let alias = root.appendingPathComponent("worktree-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realWorktree, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realWorktree)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = AgentInstanceKey(
            worktreeURL: realWorktree.appendingPathComponent(".", isDirectory: true),
            profile: "codex",
            name: "  reviewer \n"
        )
        let equivalent = AgentInstanceKey(
            worktreeURL: alias,
            profile: "codex",
            name: "reviewer"
        )

        XCTAssertEqual(original, equivalent)
        XCTAssertEqual(Set([original, equivalent]).count, 1)
        XCTAssertNotEqual(
            original,
            AgentInstanceKey(worktreeURL: realWorktree, profile: "other", name: "reviewer")
        )
        XCTAssertNotEqual(
            original,
            AgentInstanceKey(worktreeURL: realWorktree, profile: "codex", name: "Reviewer")
        )
    }

    func testWorkspaceStorePathsRemainUnchangedForAgentState() {
        let root = URL(fileURLWithPath: "/tmp/devhq-agent-persistence", isDirectory: true)
        let store = WorkspaceStateStore(
            configDirectory: root.appendingPathComponent("config", isDirectory: true),
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true)
        )

        XCTAssertEqual(
            store.repositoriesFileURL.path,
            "/tmp/devhq-agent-persistence/config/repos.jsonl"
        )
        XCTAssertEqual(
            store.worktreeStateFileURL(
                canonicalRepositoryName: "devhq",
                worktreeName: "feature/agents"
            ).path,
            "/tmp/devhq-agent-persistence/cache/devhq/feature_agents.json"
        )
    }

    func testWorkspaceStoreRoundTripsAgentsInsideRepositoryWorktrees() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStateStore(
            configDirectory: root.appendingPathComponent("config", isDirectory: true),
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true)
        )
        let expected = PersistedRepositoryState(
            canonicalName: "devhq",
            rootPath: "/repos/devhq",
            gitDirectoryPath: "/repos/devhq/.git",
            isExpanded: true,
            worktrees: [
                PersistedWorktreeState(
                    branchName: "main",
                    path: "/repos/devhq",
                    isMain: true,
                    isExpanded: true,
                    isSelected: true,
                    agents: [
                        PersistedAgentState(
                            profile: "codex",
                            name: "reviewer",
                            needsInput: false,
                            threadID: "thread-123"
                        )
                    ]
                )
            ]
        )

        try store.saveRepositories([expected])

        XCTAssertEqual(try store.loadRepositories(), [expected])
    }
}
