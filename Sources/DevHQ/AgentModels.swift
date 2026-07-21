import Foundation

struct AgentInstanceKey: Hashable {
    let worktreePath: String
    let profile: String
    let name: String

    init(worktreeURL: URL, profile: String, name: String) {
        self.worktreePath = worktreeURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        self.profile = profile
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PersistedAgentState: Codable, Equatable {
    let profile: String
    let name: String
    var needsInput: Bool
    var threadID: String?

    enum CodingKeys: String, CodingKey {
        case profile
        case name
        case needsInput = "needs_input"
        case threadID = "thread_id"
    }
}
