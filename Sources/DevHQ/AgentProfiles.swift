import DevHQLua
import Foundation
import Lua

@MainActor
protocol LuaPatternMatching: AnyObject {
    func firstCapture(in text: String, pattern: String) throws -> String?
}

struct AgentThreadConfiguration: Equatable {
    static let defaultDelay: TimeInterval = 1
    static let defaultSubmitDelay: TimeInterval = 0.1
    static let defaultAttempts = 50
    static let defaultInterval: TimeInterval = 0.2
    /// Keeps conversion to the nanoseconds accepted by `Task.sleep` in range.
    static let maximumTimingInterval = TimeInterval(UInt64.max / 1_000_000_000)

    let input: String?
    let pattern: String?
    let delay: TimeInterval
    let submitDelay: TimeInterval
    let attempts: Int
    let interval: TimeInterval
}

enum AgentProfileLaunchKind {
    case start
    case resume
}

enum AgentIconFont: Equatable {
    case system
}

enum AgentIconColor: Equatable {
    case accent
}

enum AgentLuaStyleSentinel {
    static let font = "devhq.native-style.font"
    static let accent = "devhq.native-style.accent"
}

@MainActor
final class LuaStyleAPI: LuaModuleRegistrable {
    let luaName = "style"

    func pushLuaTable(onto state: LuaPluginState) {
        state.newtable(nrec: 2)
        state.rawset(-1, utf8Key: "font", value: AgentLuaStyleSentinel.font)
        state.rawset(-1, utf8Key: "accent", value: AgentLuaStyleSentinel.accent)
    }
}

/// A validated snapshot of one `config.agents` entry.
///
struct AgentProfile {
    let name: String
    let start: String
    let resume: String?
    let resumeThread: String?
    let icon: String?
    let iconFont: AgentIconFont
    let iconColor: AgentIconColor?
    let thread: AgentThreadConfiguration?

    func command(for launchKind: AgentProfileLaunchKind, threadID: String?) -> String? {
        switch launchKind {
        case .start:
            start
        case .resume:
            if let threadID, !threadID.isEmpty {
                resumeThread
            } else {
                resume ?? start
            }
        }
    }
}

@MainActor
final class AgentProfileRegistry: ObservableObject {
    @Published private(set) var profiles: [AgentProfile]

    init(profiles: [AgentProfile] = [AgentProfileDefaults.codex]) {
        self.profiles = profiles.sorted { $0.name < $1.name }
    }

    func profile(named name: String) -> AgentProfile? {
        profiles.first { $0.name == name }
    }

    func replace(with profiles: [AgentProfile]) {
        self.profiles = profiles.sorted { $0.name < $1.name }
    }
}

enum AgentProfileDefaults {
    static let codexName = "codex"

    private static let codexStartBody = #"exec codex --add-dir "$REPO""#
    private static let codexResumeBody = #"exec codex --add-dir "$REPO" resume"#
    private static let codexResumeThreadBody = #"exec codex --add-dir "$REPO" resume "$THREAD_ID""#

    private static let codexStartCommand = sessionCommand(wrapping: codexStartBody)
    private static let codexResumeCommand = sessionCommand(wrapping: codexResumeBody)
    private static let codexResumeThreadCommand = sessionCommand(wrapping: codexResumeThreadBody)

    static let codex = AgentProfile(
        name: codexName,
        start: codexStartCommand,
        resume: codexResumeCommand,
        resumeThread: codexResumeThreadCommand,
        icon: "@",
        iconFont: .system,
        iconColor: nil,
        thread: AgentThreadConfiguration(
            input: "/status\n",
            pattern: "[Ss]ession%s*:%s*(%x+%-%x+%-%x+%-%x+%-%x+)",
            delay: AgentThreadConfiguration.defaultDelay,
            submitDelay: AgentThreadConfiguration.defaultSubmitDelay,
            attempts: AgentThreadConfiguration.defaultAttempts,
            interval: AgentThreadConfiguration.defaultInterval
        )
    )

    private static func sessionCommand(wrapping command: String) -> String {
        let quotedCommand = shellSingleQuote(command)
        return #"session="$REPO_ID:$AGENT_PROFILE:$AGENT_NAME"; "#
            + #"_shpool_with_config() { command -v shpool >/dev/null 2>&1 && [ -f "$HOME/.config/shpool/config.toml" ] && exec shpool -c "$HOME/.config/shpool/config.toml" attach -f -d "$PWD" -c "#
            + quotedCommand + #" "$session"; }; "#
            + #"_shpool() { command -v shpool >/dev/null 2>&1 && exec shpool attach -f -d "$PWD" -c "#
            + quotedCommand + #" "$session"; }; "#
            + #"_atch() { command -v atch >/dev/null 2>&1 && exec atch "$session" "#
            + command + #"; }; "#
            + #"_cmd() { exec "# + command + #"; }; "#
            + "_shpool_with_config || _shpool || _atch || _cmd"
    }

    /// Returns the Codex command body only for a field that still exactly matches
    /// DevHQ's built-in value. Per-field Lua overrides use the normal profile path.
    static func codexCommandBody(profileName: String, command: String) -> String? {
        guard profileName == codexName else { return nil }
        return switch command {
        case codexStartCommand:
            codexStartBody
        case codexResumeCommand:
            codexResumeBody
        case codexResumeThreadCommand:
            codexResumeThreadBody
        default:
            nil
        }
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func pushCodexTable(onto state: LuaPluginState) {
        state.newtable(nrec: 7)
        state.rawset(-1, utf8Key: "start", value: codex.start)
        if let resume = codex.resume {
            state.rawset(-1, utf8Key: "resume", value: resume)
        }
        if let resumeThread = codex.resumeThread {
            state.rawset(-1, utf8Key: "resume_thread", value: resumeThread)
        }
        if let icon = codex.icon {
            state.rawset(-1, utf8Key: "icon", value: icon)
        }
        if let thread = codex.thread {
            state.newtable(nrec: 6)
            if let input = thread.input {
                state.rawset(-1, utf8Key: "input", value: input)
            }
            if let pattern = thread.pattern {
                state.rawset(-1, utf8Key: "pattern", value: pattern)
            }
            state.rawset(-1, utf8Key: "delay", value: thread.delay)
            state.rawset(-1, utf8Key: "submit_delay", value: thread.submitDelay)
            state.rawset(-1, utf8Key: "attempts", value: thread.attempts)
            state.rawset(-1, utf8Key: "interval", value: thread.interval)
            state.rawset(-2, utf8Key: "thread")
        }
    }
}

enum AgentProfileConfigurationError: LocalizedError, Equatable {
    case agentsMustBeTable
    case invalidProfileName
    case profileMustBeTable(String)
    case requiredCommand(String, String)
    case invalidString(String, String)
    case invalidStyleValue(String, String)
    case threadMustBeTable(String)
    case invalidNumber(String, String, allowsZero: Bool)
    case invalidAttempts(String)

    var errorDescription: String? {
        switch self {
        case .agentsMustBeTable:
            "config.agents must be a table."
        case .invalidProfileName:
            "config.agents keys must be non-empty strings."
        case .profileMustBeTable(let profile):
            "config.agents.\(profile) must be a table."
        case let .requiredCommand(profile, field):
            "config.agents.\(profile).\(field) must be a non-empty shell command."
        case let .invalidString(profile, field):
            "config.agents.\(profile).\(field) must be a string."
        case let .invalidStyleValue(profile, field):
            "config.agents.\(profile).\(field) must be a value from the native style module."
        case .threadMustBeTable(let profile):
            "config.agents.\(profile).thread must be a table."
        case let .invalidNumber(profile, field, allowsZero):
            "config.agents.\(profile).thread.\(field) must be finite, "
                + (allowsZero ? "nonnegative" : "positive")
                + ", and no greater than \(Int(AgentThreadConfiguration.maximumTimingInterval)) seconds."
        case .invalidAttempts(let profile):
            "config.agents.\(profile).thread.attempts must be a positive integer."
        }
    }
}

enum AgentProfileConfiguration {
    static func decode(from state: LuaPluginState) throws -> [AgentProfile] {
        state.getglobal("config")
        defer { state.pop() }
        guard state.type(-1) == .table else {
            throw AgentProfileConfigurationError.agentsMustBeTable
        }
        state.rawget(-1, utf8Key: "agents")
        defer { state.pop() }
        guard state.type(-1) == .table else {
            throw AgentProfileConfigurationError.agentsMustBeTable
        }

        let agentsIndex = state.absindex(-1)
        var profiles: [AgentProfile] = []
        for (keyIndex, valueIndex) in state.pairs(agentsIndex) {
            guard state.type(keyIndex) == .string,
                  let name = state.tostring(keyIndex),
                  isValidName(name) else {
                throw AgentProfileConfigurationError.invalidProfileName
            }
            guard state.type(valueIndex) == .table else {
                throw AgentProfileConfigurationError.profileMustBeTable(name)
            }
            profiles.append(try decodeProfile(named: name, from: state, at: valueIndex))
        }
        if !profiles.contains(where: { $0.name == AgentProfileDefaults.codexName }) {
            profiles.append(AgentProfileDefaults.codex)
        }
        return profiles.sorted { $0.name < $1.name }
    }

    private static func decodeProfile(
        named name: String,
        from state: LuaPluginState,
        at tableIndex: CInt
    ) throws -> AgentProfile {
        let defaults = name == AgentProfileDefaults.codexName ? AgentProfileDefaults.codex : nil
        let start = try command(
            named: "start",
            from: state,
            at: tableIndex,
            profile: name,
            fallback: defaults?.start,
            required: true
        )!
        let resume = try command(
            named: "resume",
            from: state,
            at: tableIndex,
            profile: name,
            fallback: defaults?.resume,
            required: false
        )
        let resumeThread = try command(
            named: "resume_thread",
            from: state,
            at: tableIndex,
            profile: name,
            fallback: defaults?.resumeThread,
            required: false
        )
        let icon = try optionalString(
            named: "icon",
            from: state,
            at: tableIndex,
            profile: name,
            fallback: defaults?.icon,
            emptyIsInvalid: true
        )
        let iconFont = try iconFont(
            from: state,
            at: tableIndex,
            profile: name,
            fallback: defaults?.iconFont ?? .system
        )
        let iconColor = try iconColor(
            from: state,
            at: tableIndex,
            profile: name,
            fallback: defaults?.iconColor
        )
        let thread = try threadConfiguration(
            from: state,
            at: tableIndex,
            profile: name,
            fallback: defaults?.thread
        )
        return AgentProfile(
            name: name,
            start: start,
            resume: resume,
            resumeThread: resumeThread,
            icon: icon,
            iconFont: iconFont,
            iconColor: iconColor,
            thread: thread
        )
    }

    private static func command(
        named field: String,
        from state: LuaPluginState,
        at tableIndex: CInt,
        profile: String,
        fallback: String?,
        required: Bool
    ) throws -> String? {
        state.rawget(tableIndex, utf8Key: field)
        defer { state.pop() }
        if state.type(-1) == .nil {
            if let fallback { return fallback }
            if required { throw AgentProfileConfigurationError.requiredCommand(profile, field) }
            return nil
        }
        guard state.type(-1) == .string, let value = state.tostring(-1) else {
            throw AgentProfileConfigurationError.invalidString(profile, field)
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.utf8.contains(0) else {
            throw AgentProfileConfigurationError.requiredCommand(profile, field)
        }
        return value
    }

    private static func optionalString(
        named field: String,
        from state: LuaPluginState,
        at tableIndex: CInt,
        profile: String,
        fallback: String?,
        emptyIsInvalid: Bool
    ) throws -> String? {
        state.rawget(tableIndex, utf8Key: field)
        defer { state.pop() }
        if state.type(-1) == .nil { return fallback }
        guard state.type(-1) == .string, let value = state.tostring(-1) else {
            throw AgentProfileConfigurationError.invalidString(profile, field)
        }
        if (emptyIsInvalid && value.isEmpty) || value.utf8.contains(0) {
            throw AgentProfileConfigurationError.invalidString(profile, field)
        }
        return value
    }

    private static func iconFont(
        from state: LuaPluginState,
        at tableIndex: CInt,
        profile: String,
        fallback: AgentIconFont
    ) throws -> AgentIconFont {
        state.rawget(tableIndex, utf8Key: "icon_font")
        defer { state.pop() }
        if state.type(-1) == .nil { return fallback }
        guard state.type(-1) == .string,
              state.tostring(-1) == AgentLuaStyleSentinel.font else {
            throw AgentProfileConfigurationError.invalidStyleValue(profile, "icon_font")
        }
        return .system
    }

    private static func iconColor(
        from state: LuaPluginState,
        at tableIndex: CInt,
        profile: String,
        fallback: AgentIconColor?
    ) throws -> AgentIconColor? {
        state.rawget(tableIndex, utf8Key: "icon_color")
        defer { state.pop() }
        if state.type(-1) == .nil { return fallback }
        guard state.type(-1) == .string,
              state.tostring(-1) == AgentLuaStyleSentinel.accent else {
            throw AgentProfileConfigurationError.invalidStyleValue(profile, "icon_color")
        }
        return .accent
    }

    private static func threadConfiguration(
        from state: LuaPluginState,
        at tableIndex: CInt,
        profile: String,
        fallback: AgentThreadConfiguration?
    ) throws -> AgentThreadConfiguration? {
        state.rawget(tableIndex, utf8Key: "thread")
        defer { state.pop() }
        if state.type(-1) == .nil { return fallback }
        guard state.type(-1) == .table else {
            throw AgentProfileConfigurationError.threadMustBeTable(profile)
        }
        let threadIndex = state.absindex(-1)
        let input = try optionalString(
            named: "input",
            from: state,
            at: threadIndex,
            profile: profile,
            fallback: nil,
            emptyIsInvalid: false
        )
        let pattern = try optionalString(
            named: "pattern",
            from: state,
            at: threadIndex,
            profile: profile,
            fallback: nil,
            emptyIsInvalid: true
        )
        let delay = try number(
            named: "delay",
            from: state,
            at: threadIndex,
            profile: profile,
            defaultValue: AgentThreadConfiguration.defaultDelay,
            mayBeZero: true
        )
        let submitDelay = try number(
            named: "submit_delay",
            from: state,
            at: threadIndex,
            profile: profile,
            defaultValue: AgentThreadConfiguration.defaultSubmitDelay,
            mayBeZero: true
        )
        let attempts = try attempts(from: state, at: threadIndex, profile: profile)
        let interval = try number(
            named: "interval",
            from: state,
            at: threadIndex,
            profile: profile,
            defaultValue: AgentThreadConfiguration.defaultInterval,
            mayBeZero: false
        )
        return AgentThreadConfiguration(
            input: input,
            pattern: pattern,
            delay: delay,
            submitDelay: submitDelay,
            attempts: attempts,
            interval: interval
        )
    }

    private static func number(
        named field: String,
        from state: LuaPluginState,
        at tableIndex: CInt,
        profile: String,
        defaultValue: Double,
        mayBeZero: Bool
    ) throws -> Double {
        state.rawget(tableIndex, utf8Key: field)
        defer { state.pop() }
        if state.type(-1) == .nil { return defaultValue }
        guard state.type(-1) == .number,
              let value = state.tonumber(-1),
              value.isFinite,
              mayBeZero ? value >= 0 : value > 0,
              value <= AgentThreadConfiguration.maximumTimingInterval else {
            throw AgentProfileConfigurationError.invalidNumber(
                profile,
                field,
                allowsZero: mayBeZero
            )
        }
        return value
    }

    private static func attempts(
        from state: LuaPluginState,
        at tableIndex: CInt,
        profile: String
    ) throws -> Int {
        state.rawget(tableIndex, utf8Key: "attempts")
        defer { state.pop() }
        if state.type(-1) == .nil { return AgentThreadConfiguration.defaultAttempts }
        guard state.type(-1) == .number,
              let rawValue = state.tointeger(-1),
              rawValue > 0,
              rawValue <= lua_Integer(Int.max) else {
            throw AgentProfileConfigurationError.invalidAttempts(profile)
        }
        return Int(rawValue)
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.utf8.contains(0)
    }
}
