import Lua
import XCTest
@testable import DevHQ

final class AgentProfileConfigurationTests: XCTestCase {
    @MainActor
    func testDefaultCodexProfileUsesSessionManagersAndCodexRepositoryAccess() throws {
        let profile = AgentProfileDefaults.codex

        XCTAssertEqual(profile.name, "codex")
        XCTAssertEqual(profile.icon, "@")
        XCTAssertEqual(profile.iconFont, .system)
        XCTAssertTrue(profile.start.contains("command -v shpool"))
        XCTAssertTrue(profile.start.contains("command -v atch"))
        XCTAssertTrue(profile.start.contains(#"codex --add-dir "$REPO""#))
        XCTAssertTrue(profile.start.contains("$REPO_ID:$AGENT_PROFILE:$AGENT_NAME"))
        XCTAssertFalse(profile.start.contains("/bin/sh -lc"))
        XCTAssertFalse(profile.start.contains("${SHELL:-sh}"))
        XCTAssertEqual(
            AgentProfileDefaults.codexCommandBody(profileName: "codex", command: profile.start),
            #"exec codex --add-dir "$REPO""#
        )
        XCTAssertTrue(try XCTUnwrap(profile.resume).contains(" resume"))
        let resumeThread = try XCTUnwrap(profile.resumeThread)
        XCTAssertTrue(resumeThread.contains("$THREAD_ID"))
        XCTAssertEqual(
            AgentProfileDefaults.codexCommandBody(profileName: "codex", command: resumeThread),
            #"exec codex --add-dir "$REPO" resume "$THREAD_ID""#
        )
        XCTAssertNil(AgentProfileDefaults.codexCommandBody(profileName: "other", command: profile.start))
        XCTAssertNil(AgentProfileDefaults.codexCommandBody(
            profileName: "codex",
            command: profile.start + " "
        ))
        XCTAssertEqual(profile.thread?.input, "/status\n")
        XCTAssertNotNil(profile.thread?.pattern)
    }

    @MainActor
    func testCodexShpoolForwardsEnvironmentThroughCleanDaemonWithoutInjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureURL = directory.appendingPathComponent("codex-arguments")
        let environmentCaptureURL = directory.appendingPathComponent("codex-environment")
        let shellCaptureURL = directory.appendingPathComponent("shell-arguments")
        let injectionMarker = directory.appendingPathComponent("outer-expanded")
        let fakeShpool = directory.appendingPathComponent("shpool")
        try """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-c" ]; then
            command=$2
            break
          fi
          shift
        done
        [ -n "$command" ] || exit 64
        # Model a shpool daemon that does not retain client-only agent variables.
        exec /usr/bin/env -i PATH="$PATH" CAPTURE="$CAPTURE" ENV_CAPTURE="$ENV_CAPTURE" \
          SHELL_CAPTURE="$SHELL_CAPTURE" /bin/sh -c 'eval "set -- $1"; exec "$@"' helper "$command"
        """.write(to: fakeShpool, atomically: true, encoding: .utf8)
        let fakeFish = directory.appendingPathComponent("fake fish")
        try """
        #!/bin/sh
        printf '%s\\0' "$@" > "$SHELL_CAPTURE"
        [ "$1" = "-l" ] || exit 65
        [ "$2" = "-c" ] || exit 66
        exec /bin/sh -c "$3"
        """.write(to: fakeFish, atomically: true, encoding: .utf8)
        let fakeCodex = directory.appendingPathComponent("codex")
        try """
        #!/bin/sh
        printf '%s\\0' "$@" > "$CAPTURE"
        printf '%s\\0' "$REPO" "$REPO_ID" "$AGENT_PROFILE" "$AGENT_NAME" "$THREAD_ID" > "$ENV_CAPTURE"
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        for executable in [fakeShpool, fakeFish, fakeCodex] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        let hostileRepository = "/tmp/quote'\"$(touch \(injectionMarker.path))\nsecond line"
        let agentEnvironment = [
            "REPO": hostileRepository,
            "REPO_ID": "repo'$(false)\nline",
            "AGENT_PROFILE": "codex",
            "AGENT_NAME": "safe-name",
            "THREAD_ID": ""
        ]
        let body = try XCTUnwrap(AgentProfileDefaults.codexCommandBody(
            profileName: "codex",
            command: AgentProfileDefaults.codex.start
        ))
        let arguments = WorkspaceModel.codexSessionCommandArguments(
            commandBody: body,
            environment: agentEnvironment,
            processEnvironment: ["SHELL": fakeFish.path]
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.environment = [
            "PATH": directory.path + ":/usr/bin:/bin",
            "HOME": directory.path,
            "PWD": directory.path,
            "CAPTURE": captureURL.path,
            "ENV_CAPTURE": environmentCaptureURL.path,
            "SHELL_CAPTURE": shellCaptureURL.path
        ]
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try nulSeparatedStrings(in: captureURL), ["--add-dir", hostileRepository])
        XCTAssertEqual(
            try nulSeparatedStrings(in: environmentCaptureURL),
            [hostileRepository, try XCTUnwrap(agentEnvironment["REPO_ID"]), "codex", "safe-name", ""]
        )
        XCTAssertEqual(
            try nulSeparatedStrings(in: shellCaptureURL),
            ["-l", "-c", #"exec codex --add-dir "$REPO""#]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: injectionMarker.path))
    }

    @MainActor
    func testCodexResumeThreadForwardsRepositoryAndThreadID() throws {
        let command = try XCTUnwrap(AgentProfileDefaults.codex.resumeThread)
        let body = try XCTUnwrap(
            AgentProfileDefaults.codexCommandBody(profileName: "codex", command: command)
        )
        let arguments = WorkspaceModel.codexSessionCommandArguments(
            commandBody: body,
            environment: [
                "REPO": "/tmp/repository",
                "REPO_ID": "repo",
                "AGENT_PROFILE": "codex",
                "AGENT_NAME": "reviewer",
                "THREAD_ID": "thread-42"
            ],
            processEnvironment: ["SHELL": "/tmp/fish"]
        )

        XCTAssertEqual(body, #"exec codex --add-dir "$REPO" resume "$THREAD_ID""#)
        XCTAssertTrue(arguments.contains("REPO=/tmp/repository"))
        XCTAssertTrue(arguments.contains("THREAD_ID=thread-42"))
        XCTAssertEqual(Array(arguments.dropLast(1).suffix(2)), ["/bin/sh", "-c"])
        XCTAssertFalse(arguments.joined(separator: " ").contains("/bin/sh -lc"))
        XCTAssertTrue(arguments.last?.contains("'/tmp/fish' '-l' '-c'") == true)
        XCTAssertTrue(arguments.last?.contains("'THREAD_ID=thread-42'") == true)
    }

    @MainActor
    func testLuaProfilesAreSortedAndCodexFieldsMergeAtTopLevel() throws {
        let directory = try makeConfigurationDirectory(script: """
        local style = require "style"
        assert(style == _G.style)
        assert(style == require("devhq").style)
        config.agents.codex = {
          resume = "custom-codex-resume",
          icon_color = style.accent,
          thread = { pattern = "Thread:%s*(%S+)", attempts = 3 },
        }
        config.agents.claude = {
          start = "claude --cwd $PWD",
          icon = "C",
          icon_font = style.font,
          thread = {
            input = "/status\\n", pattern = "ID:%s*(%S+)",
            delay = 2, submit_delay = 0, attempts = 4, interval = 0.5,
          },
        }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let host = LuaPluginHost(settings: EditorSettings(), configDirectory: directory)
        host.loadUserConfiguration()

        XCTAssertNil(host.settings.pluginError)
        XCTAssertEqual(host.agentProfileRegistry.profiles.map(\.name), ["claude", "codex"])

        let claude = try XCTUnwrap(host.agentProfileRegistry.profile(named: "claude"))
        XCTAssertEqual(claude.start, "claude --cwd $PWD")
        XCTAssertNil(claude.resume)
        XCTAssertNil(claude.resumeThread)
        XCTAssertEqual(claude.icon, "C")
        XCTAssertEqual(claude.iconFont, .system)
        XCTAssertEqual(claude.thread?.input, "/status\n")
        XCTAssertEqual(claude.thread?.pattern, "ID:%s*(%S+)")
        XCTAssertEqual(claude.thread?.delay, 2)
        XCTAssertEqual(claude.thread?.submitDelay, 0)
        XCTAssertEqual(claude.thread?.attempts, 4)
        XCTAssertEqual(claude.thread?.interval, 0.5)

        let codex = try XCTUnwrap(host.agentProfileRegistry.profile(named: "codex"))
        XCTAssertTrue(codex.start.contains("codex --add-dir"))
        XCTAssertEqual(codex.resume, "custom-codex-resume")
        XCTAssertTrue(try XCTUnwrap(codex.resumeThread).contains("$THREAD_ID"))
        XCTAssertEqual(codex.icon, "@")
        XCTAssertEqual(codex.iconColor, .accent)
        XCTAssertNil(codex.thread?.input, "A supplied thread table replaces the default thread table")
        XCTAssertEqual(codex.thread?.pattern, "Thread:%s*(%S+)")
        XCTAssertEqual(codex.thread?.delay, 1)
        XCTAssertEqual(codex.thread?.submitDelay, 0.1)
        XCTAssertEqual(codex.thread?.attempts, 3)
        XCTAssertEqual(codex.thread?.interval, 0.2)
    }

    @MainActor
    func testCodexRemainsAvailableWhenUserReplacesAgentsTable() throws {
        let directory = try makeConfigurationDirectory(script: """
        config.agents = { zed = { start = "zed-agent" } }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let host = LuaPluginHost(settings: EditorSettings(), configDirectory: directory)
        host.loadUserConfiguration()

        XCTAssertNil(host.settings.pluginError)
        XCTAssertEqual(host.agentProfileRegistry.profiles.map(\.name), ["codex", "zed"])
    }

    @MainActor
    func testInvalidProfileLeavesPreviousRegistryAndReportsConfigurationError() throws {
        let directory = try makeConfigurationDirectory(script: """
        config.agents.broken = { start = "   ", thread = { interval = 0 } }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let host = LuaPluginHost(settings: EditorSettings(), configDirectory: directory)
        host.loadUserConfiguration()

        XCTAssertEqual(host.agentProfileRegistry.profiles.map(\.name), ["codex"])
        XCTAssertTrue(host.settings.pluginError?.contains("broken.start") == true)
    }

    func testCommandSelectionFollowsStartAndResumeRules() {
        let profile = AgentProfile(
            name: "test",
            start: "start",
            resume: nil,
            resumeThread: nil,
            icon: nil,
            iconFont: .system,
            iconColor: nil,
            thread: nil
        )

        XCTAssertEqual(profile.command(for: .start, threadID: "thread-1"), "start")
        XCTAssertEqual(profile.command(for: .resume, threadID: nil), "start")
        XCTAssertNil(profile.command(for: .resume, threadID: "thread-1"))
    }

    @MainActor
    func testLuaPatternMatcherReturnsFirstCaptureAndSurfacesInvalidPatterns() throws {
        let directory = try makeConfigurationDirectory(script: "")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = LuaPluginHost(settings: EditorSettings(), configDirectory: directory)

        XCTAssertEqual(
            try host.firstCapture(
                in: "Ready\nSession: 12345678-abcd-1234-abcd-123456789abc\n",
                pattern: "Session:%s*(%x+%-%x+%-%x+%-%x+%-%x+)"
            ),
            "12345678-abcd-1234-abcd-123456789abc"
        )
        XCTAssertNil(try host.firstCapture(in: "No session here", pattern: "Session:%s*(%S+)"))
        XCTAssertNil(
            try host.firstCapture(
                in: "Session: capture-less",
                pattern: "Session:%s*%S+"
            ),
            "A capture-less pattern must not persist its full match as a thread ID"
        )
        XCTAssertThrowsError(try host.firstCapture(in: "text", pattern: "["))
    }

    @MainActor
    func testThreadTimingRejectsValuesThatCannotConvertToSleepNanoseconds() throws {
        let directory = try makeConfigurationDirectory(script: """
        config.agents.huge = {
          start = "agent",
          thread = { pattern = "ID:(%S+)", delay = 1e100 },
        }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let host = LuaPluginHost(settings: EditorSettings(), configDirectory: directory)
        host.loadUserConfiguration()

        XCTAssertEqual(host.agentProfileRegistry.profiles.map(\.name), ["codex"])
        XCTAssertTrue(host.settings.pluginError?.contains("huge.thread.delay") == true)
        XCTAssertTrue(host.settings.pluginError?.contains("no greater than") == true)
    }

    private func makeConfigurationDirectory(script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script.write(
            to: directory.appendingPathComponent("init.lua"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    private func nulSeparatedStrings(in url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        var components = data.split(separator: 0, omittingEmptySubsequences: false)
        if components.last?.isEmpty == true { components.removeLast() }
        return try components.map { component in
            try XCTUnwrap(String(data: component, encoding: .utf8))
        }
    }
}
