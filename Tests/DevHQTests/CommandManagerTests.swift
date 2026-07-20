import Foundation
import XCTest
@testable import DevHQ

final class CommandManagerTests: XCTestCase {
    func testIdentifierValidationAndDisplayNameDerivation() throws {
        let validIdentifiers = [
            "worktree:add-repo",
            "module2:action.2",
            "my-module:do-work"
        ]
        for id in validIdentifiers {
            XCTAssertTrue(RegisteredCommand.isValidIdentifier(id), id)
        }

        let invalidIdentifiers = [
            "worktree",
            ":action",
            "module:",
            "module:action:extra",
            "Module:action",
            "module:ACTION",
            "module:under_score",
            "módulo:action",
            "module:action name"
        ]
        for id in invalidIdentifiers {
            XCTAssertFalse(RegisteredCommand.isValidIdentifier(id), id)
        }

        XCTAssertEqual(
            RegisteredCommand.title(for: "worktree:add-repo"),
            "worktree: add repo"
        )

        XCTAssertThrowsError(
            try RegisteredCommand(id: "invalid", viewKinds: [.worktree]) { _ in }
        ) { error in
            XCTAssertEqual(error as? CommandManagerError, .invalidIdentifier("invalid"))
        }
    }

    @MainActor
    func testCommandsAreFilteredByScopeAndPredicateThenSortedByDisplayName() throws {
        let manager = CommandManager()
        try manager.add(id: "worktree:remove", viewKinds: [.worktree]) { _ in }
        try manager.add(id: "worktree:add-repo", viewKinds: [.worktree]) { _ in }
        try manager.add(id: "file:open", viewKinds: [.file]) { _ in }
        try manager.add(
            id: "worktree:hidden",
            viewKinds: [.worktree],
            predicate: { _ in false }
        ) { _ in }

        let worktreeCommands = try manager.commands(in: CommandContext(view: .worktree))

        XCTAssertEqual(worktreeCommands.map(\.id), [
            "worktree:add-repo",
            "worktree:remove"
        ])
    }

    @MainActor
    func testPaletteSafeListingKeepsValidCommandsAndReportsPredicateFailures() throws {
        enum PredicateError: LocalizedError {
            case failed

            var errorDescription: String? { "plugin predicate failed" }
        }

        let manager = CommandManager()
        try manager.add(id: "file:z-last", viewKinds: [.file]) { _ in }
        try manager.add(
            id: "file:broken",
            viewKinds: [.file],
            predicate: { _ in throw PredicateError.failed }
        ) { _ in }
        try manager.add(id: "file:a-first", viewKinds: [.file]) { _ in }
        try manager.add(id: "document:outside", viewKinds: [.document]) { _ in }

        let listing = manager.commandListing(in: CommandContext(view: .file))

        XCTAssertEqual(listing.commands.map(\.id), ["file:a-first", "file:z-last"])
        XCTAssertEqual(listing.predicateFailures.map(\.commandID), ["file:broken"])
        XCTAssertEqual(
            listing.predicateFailures.first?.error.localizedDescription,
            "plugin predicate failed"
        )
    }

    @MainActor
    func testAddingTheSameIdentifierReplacesAndRemovalReportsWhetherItRemoved() throws {
        let manager = CommandManager()
        var result = ""
        XCTAssertNil(
            try manager.add(id: "document:format", viewKinds: [.document]) { _ in
                result = "first"
            }
        )

        let replaced = try manager.add(
            id: "document:format",
            viewKinds: [.document]
        ) { _ in
            result = "replacement"
        }

        XCTAssertEqual(replaced?.id, "document:format")
        XCTAssertEqual(manager.commandsByID.count, 1)
        try manager.execute(id: "document:format", in: CommandContext(view: .document))
        XCTAssertEqual(result, "replacement")
        XCTAssertTrue(manager.remove(id: "document:format"))
        XCTAssertFalse(manager.remove(id: "document:format"))
    }

    @MainActor
    func testNativeActionReceivesTheExecutionContext() throws {
        let manager = CommandManager()
        let worktreeURL = URL(fileURLWithPath: "/repos/devhq")
        let fileURL = worktreeURL.appendingPathComponent("README.md")
        var receivedContext: CommandContext?
        try manager.add(id: "file:open", viewKinds: [.file]) { context in
            receivedContext = context
        }
        let context = CommandContext(
            view: .file,
            worktreeURL: worktreeURL,
            fileURL: fileURL
        )

        try manager.execute(id: "file:open", in: context)

        XCTAssertEqual(receivedContext, context)
    }

    @MainActor
    func testExecutionRechecksPredicateAndRefusesOutOfScopeCommands() throws {
        let manager = CommandManager()
        var isEnabled = true
        var executionCount = 0
        try manager.add(
            id: "document:save",
            viewKinds: [.document],
            predicate: { _ in isEnabled }
        ) { _ in
            executionCount += 1
        }
        let documentContext = CommandContext(view: .document)
        XCTAssertEqual(try manager.commands(in: documentContext).map(\.id), ["document:save"])

        isEnabled = false
        XCTAssertThrowsError(try manager.execute(id: "document:save", in: documentContext)) {
            XCTAssertEqual(
                $0 as? CommandManagerError,
                .commandUnavailable("document:save")
            )
        }
        XCTAssertEqual(executionCount, 0)

        XCTAssertThrowsError(
            try manager.execute(id: "document:save", in: CommandContext(view: .file))
        ) {
            XCTAssertEqual(
                $0 as? CommandManagerError,
                .commandOutOfScope(id: "document:save", view: .file)
            )
        }
        XCTAssertEqual(executionCount, 0)
    }

    @MainActor
    func testUnknownCommandAndThrownPredicateAndActionErrorsAreExposed() throws {
        enum ExpectedError: Error, Equatable {
            case predicate
            case action
        }

        let manager = CommandManager()
        XCTAssertThrowsError(
            try manager.execute(id: "file:missing", in: CommandContext(view: .file))
        ) {
            XCTAssertEqual(
                $0 as? CommandManagerError,
                .commandNotFound("file:missing")
            )
        }

        try manager.add(
            id: "file:predicate-error",
            viewKinds: [.file],
            predicate: { _ in throw ExpectedError.predicate }
        ) { _ in }
        XCTAssertThrowsError(try manager.commands(in: CommandContext(view: .file))) {
            XCTAssertEqual($0 as? ExpectedError, .predicate)
        }

        try manager.add(id: "document:action-error", viewKinds: [.document]) { _ in
            throw ExpectedError.action
        }
        XCTAssertThrowsError(
            try manager.execute(id: "document:action-error", in: CommandContext(view: .document))
        ) {
            XCTAssertEqual($0 as? ExpectedError, .action)
        }
    }
}
