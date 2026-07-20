import Foundation

struct PersistedRepositoryState: Codable, Equatable {
    let canonicalName: String
    let rootPath: String
    let gitDirectoryPath: String
    let isExpanded: Bool
    let worktrees: [PersistedWorktreeState]
}

struct PersistedWorktreeState: Codable, Equatable {
    let branchName: String
    let path: String
    let isMain: Bool
    let isExpanded: Bool
    let isSelected: Bool
}

struct PersistedWorkspaceState: Codable, Equatable {
    let expandedFileNodeIDs: [String]
    let tabs: [PersistedEditorTabState]
    let selectedTabPath: String?
}

struct PersistedEditorTabState: Codable, Equatable {
    let path: String
    let unsavedText: String?
    let savedText: String?
}

protocol WorkspaceStatePersisting {
    func loadRepositories() throws -> [PersistedRepositoryState]
    func saveRepositories(_ repositories: [PersistedRepositoryState]) throws

    func loadWorkspaceState(
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws -> PersistedWorkspaceState?

    func saveWorkspaceState(
        _ state: PersistedWorkspaceState,
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws
}

struct WorkspaceStateStore: WorkspaceStatePersisting {
    let configDirectory: URL
    let cacheDirectory: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        configDirectory: URL? = nil,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        self.configDirectory = configDirectory
            ?? homeDirectory.appendingPathComponent(".config/devhq/ws", isDirectory: true)
        self.cacheDirectory = cacheDirectory
            ?? homeDirectory.appendingPathComponent(".cache/devhq/ws", isDirectory: true)
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    var repositoriesFileURL: URL {
        configDirectory.appendingPathComponent("repos.jsonl", isDirectory: false)
    }

    static func worktreeFileName(for worktreeName: String) -> String {
        worktreeName.replacingOccurrences(of: "/", with: "_") + ".json"
    }

    func worktreeStateFileURL(
        canonicalRepositoryName: String,
        worktreeName: String
    ) -> URL {
        cacheDirectory
            .appendingPathComponent(canonicalRepositoryName, isDirectory: true)
            .appendingPathComponent(Self.worktreeFileName(for: worktreeName), isDirectory: false)
    }

    func loadRepositories() throws -> [PersistedRepositoryState] {
        guard fileManager.fileExists(atPath: repositoriesFileURL.path) else { return [] }

        let data = try Data(contentsOf: repositoriesFileURL)
        guard !data.isEmpty else { return [] }

        return try data.split(separator: UInt8(ascii: "\n"))
            .filter { !$0.isEmpty }
            .map { try decoder.decode(PersistedRepositoryState.self, from: Data($0)) }
    }

    func saveRepositories(_ repositories: [PersistedRepositoryState]) throws {
        try fileManager.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )

        var contents = Data()
        for repository in repositories {
            contents.append(try encoder.encode(repository))
            contents.append(UInt8(ascii: "\n"))
        }
        try contents.write(to: repositoriesFileURL, options: .atomic)
    }

    func loadWorkspaceState(
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws -> PersistedWorkspaceState? {
        let fileURL = worktreeStateFileURL(
            canonicalRepositoryName: canonicalRepositoryName,
            worktreeName: worktreeName
        )
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try decoder.decode(PersistedWorkspaceState.self, from: Data(contentsOf: fileURL))
    }

    func saveWorkspaceState(
        _ state: PersistedWorkspaceState,
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws {
        let fileURL = worktreeStateFileURL(
            canonicalRepositoryName: canonicalRepositoryName,
            worktreeName: worktreeName
        )
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
