import Foundation

struct GitWorktreeInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let isMain: Bool

    init(name: String, url: URL, isMain: Bool) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.id = url.path
        self.name = name
        self.url = url
        self.isMain = isMain
    }
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

    init(
        rootURL: URL,
        name: String,
        canonicalName: String? = nil,
        gitDirectoryURL: URL,
        worktrees: [GitWorktreeInfo]
    ) {
        let rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.id = rootURL.path
        self.rootURL = rootURL
        self.name = name
        self.canonicalName = canonicalName ?? name
        self.gitDirectoryURL = gitDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        self.worktrees = worktrees
    }

    func withCanonicalName(_ canonicalName: String) -> GitRepositoryInfo {
        GitRepositoryInfo(
            rootURL: rootURL,
            name: name,
            canonicalName: canonicalName,
            gitDirectoryURL: gitDirectoryURL,
            worktrees: worktrees
        )
    }
}

protocol GitWorktreeDiscovering {
    func discover(at url: URL) throws -> GitRepositoryInfo
}
