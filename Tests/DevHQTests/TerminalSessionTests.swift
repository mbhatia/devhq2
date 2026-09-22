import Darwin
import Combine
import Foundation
import XCTest
@testable import DevHQ

final class TerminalSessionTests: XCTestCase {
    @MainActor
    func testUnchangedSizeAndMetadataDoNotRepublishState() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try TerminalSession(rootURL: root, command: ["/bin/sleep", "5"])
        defer { session.close() }
        var snapshots = 0
        var titles = 0
        var directories = 0
        let observations = [
            session.$snapshot.dropFirst().sink { _ in snapshots += 1 },
            session.$title.dropFirst().sink { _ in titles += 1 },
            session.$currentDirectory.dropFirst().sink { _ in directories += 1 }
        ]
        defer { observations.forEach { $0.cancel() } }

        // Initial bridge geometry is already 80x24 with zero pixel dimensions.
        session.resize(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        XCTAssertEqual(snapshots, 0)
        XCTAssertEqual(titles, 0)
        XCTAssertEqual(directories, 0)

        // The first actual frame still updates its native cell pixel metrics.
        session.resize(columns: 80, rows: 24, pixelWidth: 640, pixelHeight: 408)
        XCTAssertEqual(snapshots, 1)
        session.resize(columns: 80, rows: 24, pixelWidth: 640, pixelHeight: 408)
        XCTAssertEqual(snapshots, 1)
    }

    func testBELProducesAttentionEffect() {
        var parser = TerminalParser(columns: 20, rows: 2)
        parser.feed(Array("before\u{7}after".utf8))

        XCTAssertEqual(parser.takeEffects(), [.bell])
        XCTAssertTrue(parser.snapshot().cells[0].map(\.text).joined().contains("beforeafter"))
    }

    func testOSC8HyperlinksSurviveSGRAndEndExplicitly() {
        var parser = TerminalParser(columns: 20, rows: 2)
        parser.feed(Array("\u{1B}]8;id=docs;https://example.com/docs\u{1B}\\A\u{1B}[0mB\u{1B}]8;;\u{7}C".utf8))

        let cells = parser.snapshot().cells[0]
        XCTAssertEqual(cells[0].text, "A")
        XCTAssertEqual(cells[0].hyperlink, "https://example.com/docs")
        XCTAssertEqual(cells[1].hyperlink, "https://example.com/docs")
        XCTAssertNil(cells[2].hyperlink)
    }

    func testOSC9AndOSC52ProduceStrictBoundedEffects() {
        var parser = TerminalParser(columns: 20, rows: 2)
        parser.feed(Array("\u{1B}]2;Build\u{7}\u{1B}]9;Finished\u{7}\u{1B}]52;c;Y2xpcGJvYXJk\u{7}".utf8))

        XCTAssertEqual(parser.takeEffects(), [
            .notification(title: "Build", body: "Finished"),
            .clipboardWrite("clipboard")
        ])

        parser.feed(Array("\u{1B}]52;c;?\u{7}\u{1B}]52;c;not-base64!\u{7}".utf8))
        XCTAssertTrue(parser.takeEffects().isEmpty)

        parser.feed(Array("\u{1B}]52;c;\u{7}".utf8))
        XCTAssertEqual(parser.takeEffects(), [.clipboardWrite("")])

        let oversized = "\u{1B}]9;" + String(repeating: "x", count: 1024 * 1024 + 1) + "\u{7}"
        parser.feed(oversized.utf8)
        XCTAssertTrue(parser.takeEffects().isEmpty)
    }

    func testOSCEffectsCoalesceAndSequencesCanSpanChunks() {
        var parser = TerminalParser(columns: 20, rows: 2)
        for index in 0..<100 {
            parser.feed(Array("\u{1B}]9;message-\(index)\u{7}".utf8))
        }
        parser.feed(Array("\u{1B}]52;c;Zmlyc3Q=\u{7}\u{1B}]52;c;c2Vjb25k\u{7}".utf8))
        XCTAssertEqual(parser.takeEffects(), [
            .notification(title: "DevHQ Terminal", body: "message-99"),
            .clipboardWrite("second")
        ])

        parser.feed(Array("\u{1B}]9;split".utf8) + [0x1b])
        XCTAssertTrue(parser.takeEffects().isEmpty)
        parser.feed([0x5c])
        XCTAssertEqual(parser.takeEffects(), [
            .notification(title: "DevHQ Terminal", body: "split")
        ])
    }

    func testC1OSCAndSTDoNotBreakUTF8ContinuationBytes() {
        var parser = TerminalParser(columns: 20, rows: 2)
        parser.feed([0x9d] + Array("9;c1-notification".utf8))
        XCTAssertTrue(parser.takeEffects().isEmpty)
        parser.feed([0x9c])
        XCTAssertEqual(parser.takeEffects(), [
            .notification(title: "DevHQ Terminal", body: "c1-notification")
        ])

        parser.feed(Array("Ý".utf8))
        XCTAssertEqual(parser.snapshot().cells[0][0].text, "Ý")
    }

    func testEffectsOnlyParserRecognizesOSC9OSC52AndBELAcrossChunks() {
        var parser = TerminalParser(columns: 20, rows: 2, tracksCells: false)
        let first = Array("ordinary\u{1B}]9;complete\u{7}\u{1B}]52;c;Y2xpc".utf8)
        parser.feed(first[first.startIndex...])
        let second = Array("GJvYXJk\u{7}\u{7}more ordinary output".utf8)
        parser.feed(second[second.startIndex...])

        XCTAssertEqual(parser.takeEffects(), [
            .notification(title: "DevHQ Terminal", body: "complete"),
            .clipboardWrite("clipboard"),
            .bell
        ])
    }

    func testEffectsOnlyParserDistinguishesUTF8Continuation9DFromC1OSC() {
        var parser = TerminalParser(columns: 20, rows: 2, tracksCells: false)
        let leadingUTF8Byte: [UInt8] = Array("ordinary ".utf8) + [0xc3]
        parser.feed(leadingUTF8Byte[leadingUTF8Byte.startIndex...])

        // 0x9d completes the split UTF-8 encoding of "Ý"; it is not C1 OSC.
        let continuationAndText: [UInt8] = [0x9d] + Array(" ordinary".utf8)
        parser.feed(continuationAndText[continuationAndText.startIndex...])

        let actualC1OSC: [UInt8] = [0x9d] + Array("9;actual-c1".utf8) + [0x9c]
        parser.feed(actualC1OSC[actualC1OSC.startIndex...])

        XCTAssertEqual(parser.takeEffects(), [
            .notification(title: "DevHQ Terminal", body: "actual-c1")
        ])

        let bytes: [UInt8] = Array("prefix Ý suffix".utf8)
            + [0x9d] + Array("9;split-in-any-position".utf8) + [0x9c]
        for split in 0...bytes.count {
            var splitParser = TerminalParser(columns: 20, rows: 2, tracksCells: false)
            splitParser.feed(bytes[..<split])
            splitParser.feed(bytes[split...])
            XCTAssertEqual(
                splitParser.takeEffects(),
                [.notification(title: "DevHQ Terminal", body: "split-in-any-position")],
                "split at byte \(split)"
            )
        }
    }

    func testParserScrollUpShowsOlderRowsAndUsesBottomRelativeOffset() {
        var parser = TerminalParser(columns: 12, rows: 3)
        parser.feed(Array("one\ntwo\nthree\nfour\nfive".utf8))
        let bottomRows = parser.snapshot().cells.map { $0.map(\.text).joined() }

        parser.scrollViewport(lines: 1)
        let scrolled = parser.snapshot()
        let scrolledRows = scrolled.cells.map { $0.map(\.text).joined() }

        XCTAssertEqual(scrolled.scrollOffset, 1)
        XCTAssertNotEqual(scrolledRows, bottomRows)
        XCTAssertEqual(scrolledRows.dropFirst(), bottomRows.dropLast())
    }

    @MainActor
    func testHostEffectsDrainWhileInactiveAndCmdClickOpeningIsTestable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = RecordingTerminalHostServices()
        let session = try TerminalSession(rootURL: root, shell: "/bin/sh", hostServices: host)
        defer { session.close() }
        session.setActive(false)

        session.send(text: "printf '\\033]9;Discarded\\007\\033]9;Inactive\\007\\033]52;c;ZnJvbS10ZXJtaW5hbA==\\007\\033]8;;https://example.com\\033\\\\Z\\033]8;;\\007'; sleep 1\n")

        let deadline = Date().addingTimeInterval(3)
        while (host.notifications.isEmpty || host.clipboardWrites.isEmpty), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        XCTAssertEqual(host.notifications.map(\.body), ["Inactive"])
        XCTAssertEqual(host.clipboardWrites, ["from-terminal"])

        session.setActive(true)
        var opened = false
        for row in 0..<session.snapshot.rows where !opened {
            for column in 0..<session.snapshot.columns where !opened {
                opened = session.openHyperlink(at: (column, row))
            }
        }
        XCTAssertTrue(opened)
        XCTAssertEqual(host.openedURLs, [URL(string: "https://example.com")!])
    }

    @MainActor
    func testShellOutputInputTitleAndExitRemainVisible() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try TerminalSession(rootURL: root, shell: "/bin/sh")
        defer { session.close() }

        session.send(text: "printf '\\033]2;Fixture\\007hello\\n'; exit 7\n")

        let deadline = Date().addingTimeInterval(3)
        while session.exitStatus == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        XCTAssertEqual(session.title, "Fixture")
        XCTAssertEqual(session.exitStatus, 7)
        XCTAssertTrue(session.displayTitle.contains("exit 7"))
        XCTAssertTrue(session.snapshot.cells.flatMap { $0 }.map(\.text).joined().contains("hello"))
    }

    @MainActor
    func testEOFDrainsTrailingOutputBeforeExitBecomesObservable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try TerminalSession(
            rootURL: root,
            command: ["/bin/sh", "-c", "printf 'trailing-output'; exit 19"]
        )
        defer { session.close() }
        var callbackText = ""
        session.onNaturalExit = { _ in callbackText = snapshotText(session) }

        let deadline = Date().addingTimeInterval(3)
        while (session.exitStatus == nil || !snapshotText(session).contains("trailing-output")),
              Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        XCTAssertEqual(session.exitStatus, 19)
        XCTAssertTrue(snapshotText(session).contains("trailing-output"))
        XCTAssertTrue(callbackText.contains("trailing-output"))
    }

    @MainActor
    func testQuietChildDoesNotCreateOutputAndExplicitCloseDoesNotNotifyExit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try TerminalSession(
            rootURL: root,
            command: ["/bin/sh", "-c", "sleep 10"]
        )
        var naturalExitCount = 0
        session.onNaturalExit = { _ in naturalExitCount += 1 }

        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(session.processedOutputByteCount, 0)

        let closeStarted = Date()
        session.close()
        XCTAssertLessThan(Date().timeIntervalSince(closeStarted), 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(naturalExitCount, 0)
    }

    @MainActor
    func testSustainedOutputDoesNotStarveResizeOrExplicitClose() throws {
        guard TerminalSession.usesGhosttyRenderer else {
            return XCTFail("The configured DevHQ build must use libghostty")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try TerminalSession(
            rootURL: root,
            command: ["/bin/sh", "-c", "exec yes"]
        )
        var naturalExitCount = 0
        session.onNaturalExit = { _ in naturalExitCount += 1 }
        defer { session.close() }

        let deadline = Date().addingTimeInterval(2)
        while session.processedOutputByteCount == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertGreaterThan(session.processedOutputByteCount, 0)

        let resizeStarted = Date()
        session.resize(columns: 100, rows: 30, pixelWidth: 0, pixelHeight: 0)
        XCTAssertLessThan(Date().timeIntervalSince(resizeStarted), 2)
        let closeStarted = Date()
        session.close()
        XCTAssertLessThan(Date().timeIntervalSince(closeStarted), 2)
        XCTAssertEqual(naturalExitCount, 0)
    }

    @MainActor
    func testParentExitIsNotBlockedByOutputtingPTYDescendant() throws {
        guard TerminalSession.usesGhosttyRenderer else {
            return XCTFail("The configured DevHQ build must use libghostty")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The descendant ignores HUP so it retains the PTY after its shell exits.
        // `close()` below must terminate the process group and prevent an orphan.
        let session = try TerminalSession(
            rootURL: root,
            command: ["/bin/sh", "-c", "(trap '' HUP; exec yes) & exit 31"]
        )
        defer { session.close() }
        var statuses: [Int] = []
        session.onNaturalExit = { statuses.append($0) }

        let deadline = Date().addingTimeInterval(2)
        while statuses.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        XCTAssertEqual(statuses, [31])
        XCTAssertEqual(session.exitStatus, 31)
    }

    @MainActor
    func testNaturalExitCallbackFiresExactlyOnceButExplicitCloseDoesNotFireIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let natural = try TerminalSession(
            rootURL: root,
            command: ["/bin/sh", "-c", "exit 23"]
        )
        var statuses: [Int] = []
        natural.onNaturalExit = { statuses.append($0) }

        let deadline = Date().addingTimeInterval(3)
        while statuses.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(statuses, [23])
        natural.close()
        XCTAssertEqual(statuses, [23])

        let explicitlyClosed = try TerminalSession(
            rootURL: root,
            command: ["/bin/sh", "-c", "sleep 10"]
        )
        var explicitStatuses: [Int] = []
        explicitlyClosed.onNaturalExit = { explicitStatuses.append($0) }
        explicitlyClosed.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(explicitStatuses.isEmpty)
    }

    @MainActor
    func testAttentionFocusAndUserInputHooksDistinguishProgrammaticInput() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = RecordingTerminalHostServices()
        let session = try TerminalSession(rootURL: root, shell: "/bin/sh", hostServices: host)
        defer { session.close() }
        var attentionCount = 0
        var focusCount = 0
        var userInputCount = 0
        session.onAttention = { attentionCount += 1 }
        session.onFocus = { focusCount += 1 }
        session.onUserInput = { userInputCount += 1 }

        session.send(text: "printf '\\007\\033]9;attention\\007'; sleep 1\n")
        let deadline = Date().addingTimeInterval(3)
        while attentionCount < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        XCTAssertEqual(attentionCount, 2)
        XCTAssertEqual(userInputCount, 0)
        session.setFocused(true)
        session.sendUser(text: "echo user\n")
        session.sendUserSpecialKey(.escape, modifiers: [])
        session.pasteFromUser("paste")
        XCTAssertEqual(focusCount, 1)
        XCTAssertEqual(userInputCount, 3)
    }

    @MainActor
    func testVisibleTextUpdatesWhileSessionIsInactive() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try TerminalSession(rootURL: root, shell: "/bin/sh")
        defer { session.close() }
        session.setActive(false)
        session.send(text: "printf 'inactive-visible-text'; sleep 1\n")

        let deadline = Date().addingTimeInterval(3)
        while !session.visibleText.contains("inactive-visible-text"), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        XCTAssertTrue(session.visibleText.contains("inactive-visible-text"))
        XCTAssertFalse(session.snapshot.cells.flatMap { $0 }.map(\.text).joined()
            .contains("inactive-visible-text"))
    }

    @MainActor
    func testDirectCommandUsesArgumentsAndRequestedWorkingDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let session = try TerminalSession(
            rootURL: root,
            workingDirectory: workingDirectory,
            command: [
                "/bin/sh", "-c",
                "test \"$(pwd -P)\" = \"$(cd \"$1\" && pwd -P)\" || exit 4; "
                    + "printf 'direct-argv:%s' \"$2\"; exit 6",
                "launcher", workingDirectory.path, "argument"
            ],
            shell: "/does/not/exist"
        )
        defer { session.close() }

        let deadline = Date().addingTimeInterval(3)
        while session.exitStatus == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }

        XCTAssertEqual(session.currentDirectory, workingDirectory)
        XCTAssertEqual(session.exitStatus, 6)
        let output = session.snapshot.cells.flatMap { $0 }.map(\.text).joined()
        XCTAssertTrue(output.contains("direct-argv:argument"))
    }

    @MainActor
    func testSynchronizedOutputKeepsLastCompletedGhosttySnapshot() throws {
        guard TerminalSession.usesGhosttyRenderer else {
            return XCTFail("The configured DevHQ build must use libghostty")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try TerminalSession(
            rootURL: root,
            command: [
                "/bin/sh", "-c",
                "printf '\\033[?1049h\\033[2J\\033[HOLD\\033]2;baseline-ready\\007'; "
                    + "IFS= read -r _; "
                    + "printf '\\033[?2026h\\033[HNEW\\033]2;sync-pending\\007'; "
                    + "IFS= read -r _; "
                    + "printf '\\033[?2026l\\033]2;sync-complete\\007'; sleep 1"
            ]
        )
        defer { session.close() }

        let baselineDeadline = Date().addingTimeInterval(3)
        while (session.title != "baseline-ready" || !snapshotText(session).contains("OLD")),
              Date() < baselineDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertEqual(session.title, "baseline-ready")
        XCTAssertTrue(snapshotText(session).contains("OLD"))

        session.send(text: "\n")
        let pendingDeadline = Date().addingTimeInterval(3)
        while session.title != "sync-pending", Date() < pendingDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertEqual(session.title, "sync-pending")
        XCTAssertTrue(snapshotText(session).contains("OLD"))
        XCTAssertFalse(snapshotText(session).contains("NEW"))

        // Repeated layout passes must not make libghostty end the synchronized frame early.
        session.resize(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
        XCTAssertTrue(snapshotText(session).contains("OLD"))
        XCTAssertFalse(snapshotText(session).contains("NEW"))

        session.send(text: "\n")
        let completedDeadline = Date().addingTimeInterval(3)
        while (session.title != "sync-complete" || !snapshotText(session).contains("NEW")),
              Date() < completedDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertEqual(session.title, "sync-complete")
        XCTAssertTrue(snapshotText(session).contains("NEW"))
        XCTAssertFalse(snapshotText(session).contains("OLD"))
    }

    @MainActor
    func testGhosttyAlternateScreenScrollShiftsEveryVisibleRow() throws {
        guard TerminalSession.usesGhosttyRenderer else {
            return XCTFail("The configured DevHQ build must use libghostty")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try TerminalSession(
            rootURL: root,
            command: [
                "/bin/sh", "-c",
                #"stty -echo; printf '\033]2;resize-ready\007'; IFS= read -r _; "#
                    + #"printf '\033[?1049h\033[2J\033[HONE\r\nTWO\r\nTHREE"#
                    + #"\033]2;initial-screen\007'; IFS= read -r _; "#
                    + #"printf '\r\nFOUR\033]2;shifted-screen\007'; sleep 1"#
            ]
        )
        defer { session.close() }

        awaitTitle("resize-ready", in: session)
        session.resize(columns: 8, rows: 3, pixelWidth: 0, pixelHeight: 0)
        session.send(text: "\n")

        awaitTitle("initial-screen", in: session)
        XCTAssertEqual(snapshotRows(session), ["ONE", "TWO", "THREE"])

        session.send(text: "\n")
        awaitTitle("shifted-screen", in: session)
        XCTAssertEqual(snapshotRows(session), ["TWO", "THREE", "FOUR"])
    }

    @MainActor
    func testNativePositiveScrollShowsOlderContentWithBottomRelativeOffset() throws {
        guard TerminalSession.usesGhosttyRenderer else {
            return XCTFail("The configured DevHQ build must use libghostty")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try TerminalSession(
            rootURL: root,
            command: [
                "/bin/sh", "-c",
                "printf '\\033]2;scroll-ready\\007'; IFS= read -r _; "
                    + "i=1; while [ $i -le 20 ]; do printf 'line%02d\\r\\n' $i; "
                    + "i=$((i+1)); done; exec /bin/cat"
            ]
        )
        defer { session.close() }

        session.resize(columns: 12, rows: 3, pixelWidth: 0, pixelHeight: 0)
        awaitTitle("scroll-ready", in: session)
        session.send(text: "\n")
        let deadline = Date().addingTimeInterval(3)
        while (session.snapshot.scrollbackCount < 3 || !snapshotText(session).contains("line20")),
              Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let bottomRows = session.snapshot.cells

        session.scroll(lines: 2)
        let scrolled = session.snapshot
        XCTAssertEqual(scrolled.scrollOffset, 2)
        XCTAssertNotEqual(scrolled.cells, bottomRows)
        XCTAssertEqual(scrolled.cells.dropFirst(2), bottomRows.dropLast(2))
    }

    @MainActor
    func testMixedTabsSurviveWorktreeSwitchAndPersistenceContainsOnlyFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let file = first.appendingPathComponent("File.swift")
        try "let value = 1".write(to: file, atomically: true, encoding: .utf8)
        let store = TerminalTestWorkspaceStore()
        let model = WorkspaceModel(arguments: ["DevHQ"], stateStore: store)

        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: first)
        model.openFile(file)
        let terminal = try model.newTerminal(shell: "/bin/sh")
        let pid = terminal.processID
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.selectedTerminal?.id, terminal.id)

        model.saveCurrentWorkspaceState()
        let saved = try XCTUnwrap(store.workspaceState(repository: "repo", worktree: "main"))
        XCTAssertEqual(saved.tabs.map { $0.path }, ["File.swift"])
        XCTAssertEqual(saved.selectedTabPath, "File.swift")

        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "feature", url: second)
        XCTAssertTrue(model.tabs.isEmpty)
        model.openWorktree(canonicalRepositoryName: "repo", worktreeName: "main", url: first)

        XCTAssertEqual(model.selectedTerminal?.id, terminal.id)
        XCTAssertEqual(model.selectedTerminal?.processID, pid)
        XCTAssertEqual(model.tabs.map { $0.id }, [model.documents[0].id, terminal.id])
        model.closeAllTerminals()
    }

    @MainActor
    func testClosingTerminalTerminatesOnlyItsProcess() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["DevHQ"])
        model.openWorkspace(root)
        let first = try model.newTerminal(shell: "/bin/sh")
        let second = try model.newTerminal(shell: "/bin/sh")
        let firstPID = first.processID
        let secondPID = second.processID

        model.close(first)

        XCTAssertEqual(kill(firstPID, 0), -1)
        XCTAssertEqual(kill(secondPID, 0), 0)
        XCTAssertEqual(model.terminalSessions.map(\.id), [second.id])
        model.closeAllTerminals()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
private func snapshotText(_ session: TerminalSession) -> String {
    session.snapshot.cells.flatMap { $0 }.map(\.text).joined()
}

@MainActor
private func snapshotRows(_ session: TerminalSession) -> [String] {
    session.snapshot.cells.map {
        $0.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    }
}

@MainActor
private func awaitTitle(_ title: String, in session: TerminalSession) {
    let deadline = Date().addingTimeInterval(3)
    while session.title != title, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
    XCTAssertEqual(session.title, title)
}

@MainActor
private final class RecordingTerminalHostServices: TerminalHostServices {
    struct Notification: Equatable {
        let title: String
        let body: String
    }

    private(set) var openedURLs: [URL] = []
    private(set) var notifications: [Notification] = []
    private(set) var clipboardWrites: [String] = []

    func open(url: URL) { openedURLs.append(url) }

    func showNotification(title: String, body: String) {
        notifications.append(Notification(title: title, body: body))
    }

    func writeClipboard(_ string: String) { clipboardWrites.append(string) }
}

private final class TerminalTestWorkspaceStore: WorkspaceStatePersisting {
    private var states: [String: PersistedWorkspaceState] = [:]

    func loadRepositories() throws -> [PersistedRepositoryState] { [] }
    func saveRepositories(_ repositories: [PersistedRepositoryState]) throws {}

    func loadWorkspaceState(
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws -> PersistedWorkspaceState? {
        states[canonicalRepositoryName + "\u{0}" + worktreeName]
    }

    func saveWorkspaceState(
        _ state: PersistedWorkspaceState,
        canonicalRepositoryName: String,
        worktreeName: String
    ) throws {
        states[canonicalRepositoryName + "\u{0}" + worktreeName] = state
    }

    func workspaceState(repository: String, worktree: String) -> PersistedWorkspaceState? {
        states[repository + "\u{0}" + worktree]
    }
}
