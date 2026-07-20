import XCTest
@testable import DevHQ

final class CommandPaletteTests: XCTestCase {
    @MainActor
    func testPresentationSnapshotsContextAndAlphabeticalInScopeCommands() throws {
        let manager = CommandManager()
        try manager.add(id: "worktree:add-repo", viewKinds: [.worktree]) { _ in }
        try manager.add(id: "file:new-dir", viewKinds: [.file]) { _ in }
        try manager.add(id: "file:close", viewKinds: [.file]) { _ in }

        let controller = CommandPaletteController(commandManager: manager)
        let context = CommandContext(
            view: .file,
            fileURL: URL(fileURLWithPath: "/tmp/project")
        )
        controller.present(in: context)

        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.presentedContext, context)
        XCTAssertEqual(
            controller.filteredCommands.map(\.title),
            ["file: close", "file: new dir"]
        )
        XCTAssertEqual(controller.selectedCommandID, "file:close")
    }

    @MainActor
    func testPresentationKeepsValidCommandsWhenOnePredicateThrows() throws {
        enum PredicateError: LocalizedError {
            case failed

            var errorDescription: String? { "Lua predicate failed" }
        }

        let manager = CommandManager()
        try manager.add(id: "file:new", viewKinds: [.file]) { _ in }
        try manager.add(
            id: "file:broken-plugin-command",
            viewKinds: [.file],
            predicate: { _ in throw PredicateError.failed }
        ) { _ in }
        try manager.add(id: "file:close", viewKinds: [.file]) { _ in }

        let controller = CommandPaletteController(commandManager: manager)
        controller.present(in: CommandContext(view: .file))

        XCTAssertEqual(controller.commands.map(\.id), ["file:close", "file:new"])
        XCTAssertEqual(controller.selectedCommandID, "file:close")
        XCTAssertEqual(
            controller.errorMessage,
            "Could not evaluate file:broken-plugin-command: Lua predicate failed"
        )
    }

    @MainActor
    func testQueryFiltersCaseInsensitivelyWithoutChangingAlphabeticalOrder() throws {
        let manager = CommandManager()
        try manager.add(id: "file:new-dir", viewKinds: [.file]) { _ in }
        try manager.add(id: "file:new", viewKinds: [.file]) { _ in }
        try manager.add(id: "file:close", viewKinds: [.file]) { _ in }

        let controller = CommandPaletteController(commandManager: manager)
        controller.present(in: CommandContext(view: .file))
        controller.query = "NEW"

        XCTAssertEqual(
            controller.filteredCommands.map(\.title),
            ["file: new", "file: new dir"]
        )
        XCTAssertEqual(controller.selectedCommandID, "file:new")

        controller.query = "missing"
        XCTAssertTrue(controller.filteredCommands.isEmpty)
        XCTAssertNil(controller.selectedCommandID)
    }

    @MainActor
    func testSelectionMovementWrapsWithinFilteredCommands() throws {
        let manager = CommandManager()
        try manager.add(id: "file:a", viewKinds: [.file]) { _ in }
        try manager.add(id: "file:b", viewKinds: [.file]) { _ in }
        try manager.add(id: "file:c", viewKinds: [.file]) { _ in }

        let controller = CommandPaletteController(commandManager: manager)
        controller.present(in: CommandContext(view: .file))

        XCTAssertEqual(controller.selectedCommandID, "file:a")
        controller.moveSelectionUp()
        XCTAssertEqual(controller.selectedCommandID, "file:c")
        controller.moveSelectionDown()
        XCTAssertEqual(controller.selectedCommandID, "file:a")
        controller.moveSelectionDown()
        XCTAssertEqual(controller.selectedCommandID, "file:b")
    }

    @MainActor
    func testExecutionRechecksPredicateSurfacesErrorAndDismissesAfterSuccess() throws {
        let manager = CommandManager()
        var isAvailable = true
        var executedContext: CommandContext?
        try manager.add(
            id: "file:close",
            viewKinds: [.document],
            predicate: { _ in isAvailable },
            action: { executedContext = $0 }
        )

        let controller = CommandPaletteController(commandManager: manager)
        let context = CommandContext(
            view: .document,
            documentURL: URL(fileURLWithPath: "/tmp/project/File.swift")
        )
        controller.present(in: context)

        isAvailable = false
        controller.executeSelected()
        XCTAssertTrue(controller.isPresented)
        XCTAssertNil(executedContext)
        XCTAssertEqual(
            controller.errorMessage,
            CommandManagerError.commandUnavailable("file:close").localizedDescription
        )

        isAvailable = true
        controller.executeSelected()
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(executedContext, context)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testDismissClearsPresentationState() throws {
        let manager = CommandManager()
        try manager.add(id: "file:new", viewKinds: [.file]) { _ in }

        let controller = CommandPaletteController(commandManager: manager)
        controller.present(in: CommandContext(view: .file))
        controller.query = "new"
        controller.dismiss()

        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(controller.query, "")
        XCTAssertTrue(controller.commands.isEmpty)
        XCTAssertNil(controller.selectedCommandID)
        XCTAssertNil(controller.presentedContext)
        XCTAssertNil(controller.errorMessage)
    }
}
