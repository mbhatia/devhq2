import Foundation

func agentSleepNanoseconds(for interval: TimeInterval) -> UInt64? {
    guard interval.isFinite, interval > 0 else { return nil }
    let maximumChunk: TimeInterval = 24 * 60 * 60
    return UInt64(min(interval, maximumChunk) * 1_000_000_000)
}

private func sleepForAgentInterval(_ interval: TimeInterval) async throws {
    guard agentSleepNanoseconds(for: interval) != nil else { return }
    // Keep each conversion far below UInt64's limit. Very large valid delays
    // remain cancellable and cannot trap while converting seconds to nanoseconds.
    var remaining = interval
    while let nanoseconds = agentSleepNanoseconds(for: remaining) {
        try await Task.sleep(nanoseconds: nanoseconds)
        remaining -= min(remaining, 24 * 60 * 60)
    }
}

struct AgentWorktreeContext: Equatable {
    let repositoryName: String
    let repositoryURL: URL
    let worktreeName: String
    let worktreeURL: URL

    init(repository: GitRepositoryInfo, worktree: GitWorktreeInfo) {
        repositoryName = repository.canonicalName
        repositoryURL = repository.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        worktreeName = worktree.name
        worktreeURL = worktree.url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

struct AgentRecord: Identifiable, Equatable {
    let key: AgentInstanceKey
    var context: AgentWorktreeContext
    let profile: String
    let name: String
    var needsInput: Bool
    var threadID: String?

    var id: AgentInstanceKey { key }

    var persistedState: PersistedAgentState {
        PersistedAgentState(
            profile: profile,
            name: name,
            needsInput: needsInput,
            threadID: threadID
        )
    }
}

enum AgentManagerError: LocalizedError, Equatable {
    case invalidName
    case unknownProfile(String)
    case duplicateName(profile: String, name: String)
    case unknownAgent
    case missingCommand(profile: String, launchKind: String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Agent name must not be empty."
        case .unknownProfile(let profile):
            "Agent profile '\(profile)' is not configured."
        case let .duplicateName(profile, name):
            "An agent named '\(name)' already exists for profile '\(profile)' in this worktree."
        case .unknownAgent:
            "The agent no longer exists."
        case let .missingCommand(profile, launchKind):
            switch launchKind {
            case "start":
                "Agent profile '\(profile)' has no start command."
            default:
                "Agent profile '\(profile)' has no command for resuming this agent."
            }
        }
    }
}

@MainActor
final class AgentManager: ObservableObject {
    typealias Sleeper = (TimeInterval) async throws -> Void

    @Published private(set) var records: [AgentRecord] = []

    /// Called after a worktree's persisted agent list changes.
    var onRecordsChanged: ((URL, [PersistedAgentState]) -> Void)?

    private let workspace: WorkspaceModel
    private let profiles: AgentProfileRegistry
    private let patternMatcher: LuaPatternMatching
    private let sleeper: Sleeper
    private var sessionsByAgent: [AgentInstanceKey: TerminalSession] = [:]
    private var agentsByTerminal: [UUID: AgentInstanceKey] = [:]
    private var captureTasks: [AgentInstanceKey: Task<Void, Never>] = [:]
    private var terminating = false

    init(
        workspace: WorkspaceModel,
        profiles: AgentProfileRegistry,
        patternMatcher: LuaPatternMatching,
        sleeper: @escaping Sleeper = sleepForAgentInterval
    ) {
        self.workspace = workspace
        self.profiles = profiles
        self.patternMatcher = patternMatcher
        self.sleeper = sleeper
        workspace.onTerminalExplicitlyClosed = { [weak self] terminal in
            self?.terminalWasExplicitlyClosed(terminal)
        }
    }

    func records(for worktreeURL: URL) -> [AgentRecord] {
        let path = Self.canonicalPath(worktreeURL)
        return records.filter { $0.key.worktreePath == path }
    }

    func persistedAgents(for worktreeURL: URL) -> [PersistedAgentState] {
        records(for: worktreeURL).map(\.persistedState)
    }

    func record(for key: AgentInstanceKey) -> AgentRecord? {
        records.first { $0.key == key }
    }

    func session(for key: AgentInstanceKey) -> TerminalSession? {
        sessionsByAgent[key]
    }

    func profile(named name: String) -> AgentProfile? {
        profiles.profile(named: name)
    }

    /// Restores sidebar records only. Processes are deliberately not launched
    /// until the user activates an agent.
    func restore(
        _ states: [PersistedAgentState],
        repository: GitRepositoryInfo,
        worktree: GitWorktreeInfo
    ) {
        let context = AgentWorktreeContext(repository: repository, worktree: worktree)
        let path = Self.canonicalPath(worktree.url)
        var seen = Set<AgentInstanceKey>()
        let restored = states.compactMap { state -> AgentRecord? in
            let profile = state.profile.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !profile.isEmpty, !name.isEmpty,
                  !profile.utf8.contains(0), !name.utf8.contains(0) else { return nil }
            let key = AgentInstanceKey(worktreeURL: worktree.url, profile: profile, name: name)
            guard seen.insert(key).inserted else { return nil }
            return AgentRecord(
                key: key,
                context: context,
                profile: profile,
                name: name,
                needsInput: state.needsInput,
                threadID: state.threadID.flatMap(Self.nonempty)
            )
        }

        let live = records.filter {
            $0.key.worktreePath == path && sessionsByAgent[$0.key] != nil
        }.map { record in
            var record = record
            record.context = context
            return record
        }
        records.removeAll { $0.key.worktreePath == path }
        let liveKeys = Set(live.map(\.key))
        records.append(contentsOf: restored.filter { !liveKeys.contains($0.key) })
        records.append(contentsOf: live)
        sortRecords()
        publishChange(for: worktree.url)
    }

    @discardableResult
    func create(
        profile profileName: String,
        name rawName: String,
        repository: GitRepositoryInfo,
        worktree: GitWorktreeInfo
    ) throws -> AgentRecord {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.utf8.contains(0) else {
            throw AgentManagerError.invalidName
        }
        guard let profile = profiles.profile(named: profileName) else {
            throw AgentManagerError.unknownProfile(profileName)
        }
        let key = AgentInstanceKey(
            worktreeURL: worktree.url,
            profile: profileName,
            name: name
        )
        guard !records.contains(where: { $0.key == key }) else {
            throw AgentManagerError.duplicateName(profile: profileName, name: name)
        }

        let context = AgentWorktreeContext(repository: repository, worktree: worktree)
        open(context)
        let terminal = try launch(
            profile: profile,
            name: name,
            threadID: nil,
            context: context,
            kind: .start
        )
        let record = AgentRecord(
            key: key,
            context: context,
            profile: profileName,
            name: name,
            needsInput: false,
            threadID: nil
        )
        records.append(record)
        sortRecords()
        attach(terminal, to: key, profile: profile)
        publishChange(for: worktree.url)
        return record
    }

    func activate(
        _ key: AgentInstanceKey,
        repository: GitRepositoryInfo,
        worktree: GitWorktreeInfo
    ) throws {
        guard let index = records.firstIndex(where: { $0.key == key }) else {
            throw AgentManagerError.unknownAgent
        }
        let context = AgentWorktreeContext(repository: repository, worktree: worktree)
        records[index].context = context
        open(context)

        if let terminal = sessionsByAgent[key], !terminal.hasExited {
            workspace.select(terminal)
            clearAttention(for: key)
            return
        }
        sessionsByAgent[key] = nil

        guard let profile = profiles.profile(named: records[index].profile) else {
            throw AgentManagerError.unknownProfile(records[index].profile)
        }
        let terminal = try launch(
            profile: profile,
            name: records[index].name,
            threadID: records[index].threadID,
            context: context,
            kind: .resume
        )
        attach(terminal, to: key, profile: profile)
    }

    func removeAgents(inWorktree worktreeURL: URL) {
        let keys = records(for: worktreeURL).map(\.key)
        remove(keys: keys, worktreeURLsToPublish: [worktreeURL])
    }

    func removeAgents(in repository: GitRepositoryInfo) {
        let repositoryPath = Self.canonicalPath(repository.rootURL)
        let matching = records.filter {
            $0.context.repositoryName == repository.canonicalName
                && Self.canonicalPath($0.context.repositoryURL) == repositoryPath
        }
        remove(
            keys: matching.map(\.key),
            worktreeURLsToPublish: Array(Set(matching.map { $0.context.worktreeURL }))
        )
    }

    /// Cancels capture work while preserving every record for the next app run.
    func prepareForTermination() {
        terminating = true
        captureTasks.values.forEach { $0.cancel() }
        captureTasks.removeAll()
        for record in records { publishChange(for: record.context.worktreeURL) }
    }

    private func open(_ context: AgentWorktreeContext) {
        workspace.openWorktree(
            canonicalRepositoryName: context.repositoryName,
            worktreeName: context.worktreeName,
            url: context.worktreeURL
        )
    }

    private func launch(
        profile: AgentProfile,
        name: String,
        threadID: String?,
        context: AgentWorktreeContext,
        kind: AgentProfileLaunchKind
    ) throws -> TerminalSession {
        guard let command = profile.command(for: kind, threadID: threadID) else {
            let launchKind: String = switch kind {
            case .start: "start"
            case .resume: "resume"
            }
            throw AgentManagerError.missingCommand(profile: profile.name, launchKind: launchKind)
        }
        return try workspace.newTerminal(
            workingDirectory: context.worktreeURL,
            shellCommand: command,
            environment: [
                "REPO": context.repositoryURL.path,
                "REPO_ID": context.repositoryName,
                "AGENT_PROFILE": profile.name,
                "AGENT_NAME": Self.environmentName(name),
                "THREAD_ID": threadID ?? ""
            ],
            builtInCodexBody: AgentProfileDefaults.codexCommandBody(
                profileName: profile.name,
                command: command
            )
        )
    }

    private func attach(
        _ terminal: TerminalSession,
        to key: AgentInstanceKey,
        profile: AgentProfile
    ) {
        sessionsByAgent[key] = terminal
        agentsByTerminal[terminal.id] = key
        terminal.onAttention = { [weak self] in self?.setAttention(for: key) }
        terminal.onFocus = { [weak self] in self?.clearAttention(for: key) }
        terminal.onUserInput = { [weak self] in self?.clearAttention(for: key) }
        terminal.onNaturalExit = { [weak self, weak terminal] _ in
            guard let self else { return }
            self.captureTasks.removeValue(forKey: key)?.cancel()
            self.sessionsByAgent[key] = nil
            if let terminal { self.agentsByTerminal[terminal.id] = nil }
            guard !self.terminating,
                  let record = self.record(for: key) else { return }
            self.records.removeAll { $0.key == key }
            self.publishChange(for: record.context.worktreeURL)
        }
        startThreadCaptureIfNeeded(for: key, profile: profile, terminal: terminal)
    }

    private func terminalWasExplicitlyClosed(_ terminal: TerminalSession) {
        guard let key = agentsByTerminal.removeValue(forKey: terminal.id) else { return }
        sessionsByAgent[key] = nil
        captureTasks.removeValue(forKey: key)?.cancel()
    }

    private func setAttention(for key: AgentInstanceKey) {
        guard let index = records.firstIndex(where: { $0.key == key }),
              !records[index].needsInput else { return }
        records[index].needsInput = true
        publishChange(for: records[index].context.worktreeURL)
    }

    private func clearAttention(for key: AgentInstanceKey) {
        guard let index = records.firstIndex(where: { $0.key == key }),
              records[index].needsInput else { return }
        records[index].needsInput = false
        publishChange(for: records[index].context.worktreeURL)
    }

    private func startThreadCaptureIfNeeded(
        for key: AgentInstanceKey,
        profile: AgentProfile,
        terminal: TerminalSession
    ) {
        guard record(for: key)?.threadID == nil,
              let configuration = profile.thread,
              let pattern = configuration.pattern,
              !pattern.isEmpty else { return }

        captureTasks[key]?.cancel()
        captureTasks[key] = Task { @MainActor [weak self, weak terminal] in
            guard let self else { return }
            do {
                try await self.sleeper(configuration.delay)
                try Task.checkCancellation()
                guard let terminal, !terminal.hasExited else { return }

                if let input = configuration.input {
                    let expanded = self.expandThreadInput(input, for: key)
                        .replacingOccurrences(of: "\r\n", with: "\n")
                    let pieces = expanded.split(separator: "\n", omittingEmptySubsequences: false)
                    for (index, piece) in pieces.enumerated() {
                        if !piece.isEmpty { terminal.send(text: String(piece)) }
                        if index < pieces.count - 1 {
                            try await self.sleeper(configuration.submitDelay)
                            try Task.checkCancellation()
                            terminal.send(bytes: [0x0d])
                        }
                    }
                }

                for attempt in 0..<configuration.attempts {
                    try Task.checkCancellation()
                    guard self.record(for: key) != nil, !terminal.hasExited else { return }
                    if let capture = try self.patternMatcher.firstCapture(
                        in: terminal.visibleText,
                        pattern: pattern
                    ).flatMap(Self.nonempty) {
                        self.captureTasks[key] = nil
                        guard let recordIndex = self.records.firstIndex(where: { $0.key == key }) else {
                            return
                        }
                        self.records[recordIndex].threadID = capture
                        self.publishChange(for: self.records[recordIndex].context.worktreeURL)
                        return
                    }
                    if attempt + 1 < configuration.attempts {
                        try await self.sleeper(configuration.interval)
                    }
                }
                self.captureTasks[key] = nil
            } catch {
                self.captureTasks[key] = nil
            }
        }
    }

    private func expandThreadInput(_ input: String, for key: AgentInstanceKey) -> String {
        guard let record = record(for: key) else { return input }
        let substitutions = [
            "$AGENT_PROFILE": record.profile,
            "$AGENT_NAME": Self.environmentName(record.name),
            "$THREAD_ID": record.threadID ?? ""
        ]
        var output = ""
        var index = input.startIndex
        while index < input.endIndex {
            if let match = substitutions.first(where: { token, _ in
                input[index...].hasPrefix(token)
            }) {
                output += match.value
                index = input.index(index, offsetBy: match.key.count)
            } else {
                output.append(input[index])
                index = input.index(after: index)
            }
        }
        return output
    }

    private func remove(keys: [AgentInstanceKey], worktreeURLsToPublish: [URL]) {
        let keySet = Set(keys)
        let terminals = keys.compactMap { sessionsByAgent[$0] }
        for key in keys {
            captureTasks.removeValue(forKey: key)?.cancel()
            sessionsByAgent[key] = nil
        }
        for terminal in terminals { agentsByTerminal[terminal.id] = nil }
        records.removeAll { keySet.contains($0.key) }
        for terminal in terminals { workspace.close(terminal) }
        for url in worktreeURLsToPublish { publishChange(for: url) }
    }

    private func sortRecords() {
        records.sort {
            if $0.key.worktreePath != $1.key.worktreePath {
                return $0.key.worktreePath < $1.key.worktreePath
            }
            if $0.profile != $1.profile { return $0.profile < $1.profile }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func publishChange(for worktreeURL: URL) {
        onRecordsChanged?(worktreeURL, persistedAgents(for: worktreeURL))
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func environmentName(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
    }

    private static func nonempty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
