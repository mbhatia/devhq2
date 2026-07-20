import Darwin
import Dispatch
import Foundation

protocol RepositoryWatching: AnyObject {
    func cancel()
}

typealias RepositoryWatcherFactory = (
    _ gitDirectoryURL: URL,
    _ onChange: @escaping () -> Void
) throws -> any RepositoryWatching

/// Watches the common Git directory and its linked-worktree metadata directory.
///
/// Dispatch sources are directory-local rather than recursive, so both locations
/// are watched. The sources are rebuilt after an event to pick up creation or
/// removal of the `worktrees` directory itself.
final class RepositoryWatcher: RepositoryWatching {
    enum WatchError: LocalizedError {
        case cannotOpen(URL)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let url):
                "Could not watch Git metadata at \(url.path)."
            }
        }
    }

    private let gitDirectoryURL: URL
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueValue = UUID()
    private let debounceInterval: DispatchTimeInterval
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pendingChange: DispatchWorkItem?
    private var isCancelled = false

    init(
        gitDirectoryURL: URL,
        debounceInterval: DispatchTimeInterval = .milliseconds(150),
        queue: DispatchQueue = DispatchQueue(label: "devhq.repository-watcher"),
        onChange: @escaping () -> Void
    ) throws {
        self.gitDirectoryURL = gitDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: queueValue)

        guard FileManager.default.fileExists(atPath: self.gitDirectoryURL.path) else {
            throw WatchError.cannotOpen(self.gitDirectoryURL)
        }
        try onQueue { try installSources() }
    }

    deinit {
        cancel()
    }

    func cancel() {
        onQueue {
            guard !isCancelled else { return }
            pendingChange?.cancel()
            pendingChange = nil
            isCancelled = true
            let oldSources = sources
            sources.removeAll()
            oldSources.forEach { $0.cancel() }
        }
    }

    private func installSources() throws {
        let worktreesURL = gitDirectoryURL.appendingPathComponent("worktrees", isDirectory: true)
        let urls = [gitDirectoryURL, worktreesURL].filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        var replacements: [DispatchSourceFileSystemObject] = []
        do {
            for url in urls {
                replacements.append(try makeSource(for: url))
            }
        } catch {
            replacements.forEach {
                $0.cancel()
                $0.resume()
            }
            throw error
        }

        let oldSources = sources
        sources = replacements
        oldSources.forEach { $0.cancel() }
        sources.forEach { $0.resume() }
    }

    private func makeSource(for url: URL) throws -> DispatchSourceFileSystemObject {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { throw WatchError.cannotOpen(url) }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: queue
        )
        source.setCancelHandler {
            close(descriptor)
        }
        source.setEventHandler { [weak self] in
            self?.scheduleChange()
        }
        return source
    }

    /// Serializes an incoming source event. Internal visibility also permits a
    /// deterministic cancellation test without depending on filesystem timing.
    func scheduleChange() {
        guard DispatchQueue.getSpecific(key: queueKey) == queueValue else {
            queue.async { [weak self] in self?.scheduleChange() }
            return
        }
        guard !isCancelled else { return }
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isCancelled else { return }
            // A worktree operation can create or remove `.git/worktrees`.
            try? self.installSources()
            self.onChange()
        }
        pendingChange = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func onQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }
}
