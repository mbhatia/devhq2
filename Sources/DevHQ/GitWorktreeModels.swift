import Foundation

struct GitWorktreeInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let displayName: String?
    let url: URL
    let isMain: Bool
    /// The path of this worktree on its SSH server. The local `url` remains
    /// the path used for browsing a managed mirror.
    let remotePath: String?

    init(
        name: String,
        url: URL,
        isMain: Bool,
        remotePath: String? = nil,
        displayName: String? = nil
    ) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.id = url.path
        self.name = name
        self.displayName = displayName
        self.url = url
        self.isMain = isMain
        self.remotePath = remotePath
    }

    var isRemote: Bool { remotePath != nil }
}

struct GitRepositoryInfo: Identifiable, Equatable {
    let id: String
    let rootURL: URL
    let name: String
    /// Stable user-facing repository key used for persisted workspace state.
    /// Unlike `name`, this value survives discovery refreshes and is made
    /// unique by `WorktreeExplorerModel` when the repository is first added.
    let canonicalName: String
    let gitDirectoryURL: URL
    let worktrees: [GitWorktreeInfo]
    let remoteSource: SSHRemoteRepositorySource?
    let lastSyncError: String?

    init(
        rootURL: URL,
        name: String,
        canonicalName: String? = nil,
        gitDirectoryURL: URL,
        worktrees: [GitWorktreeInfo],
        remoteSource: SSHRemoteRepositorySource? = nil,
        lastSyncError: String? = nil
    ) {
        let rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.id = rootURL.path
        self.rootURL = rootURL
        self.name = name
        self.canonicalName = canonicalName ?? name
        self.gitDirectoryURL = gitDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        self.worktrees = worktrees
        self.remoteSource = remoteSource
        self.lastSyncError = lastSyncError
    }

    var isRemote: Bool { remoteSource != nil }

    func withCanonicalName(_ canonicalName: String) -> GitRepositoryInfo {
        GitRepositoryInfo(
            rootURL: rootURL,
            name: name,
            canonicalName: canonicalName,
            gitDirectoryURL: gitDirectoryURL,
            worktrees: worktrees,
            remoteSource: remoteSource,
            lastSyncError: lastSyncError
        )
    }
}

protocol GitWorktreeDiscovering {
    func discover(at url: URL) throws -> GitRepositoryInfo
}
