import Foundation
import XCTest
@testable import DevHQ

final class WorkspaceLayoutStateTests: XCTestCase {
    private enum TestError: Error {
        case saveFailed
    }

    private final class FailingOnceLayoutStore: WorkspaceLayoutPersisting {
        private(set) var saveAttempts = 0
        private(set) var savedState: WorkspaceLayoutState?

        func load() throws -> WorkspaceLayoutState? {
            nil
        }

        func save(_ state: WorkspaceLayoutState) throws {
            saveAttempts += 1
            if saveAttempts == 1 {
                throw TestError.saveFailed
            }
            savedState = state
        }
    }

    private var temporaryDirectory: URL!
    private var store: WorkspaceLayoutStateStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = WorkspaceLayoutStateStore(configDirectory: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        store = nil
        temporaryDirectory = nil
    }

    func testDefaultPathUsesDevHQWorkspaceConfigDirectory() {
        let defaultStore = WorkspaceLayoutStateStore()
        XCTAssertEqual(
            defaultStore.layoutFileURL,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/devhq/ws/layout.json")
        )
    }

    func testMissingLayoutReturnsNil() throws {
        XCTAssertNil(try store.load())
    }

    func testSaveCreatesParentDirectoryAndRoundTripsLayout() throws {
        let nestedDirectory = temporaryDirectory
            .appendingPathComponent("nested/config", isDirectory: true)
        let nestedStore = WorkspaceLayoutStateStore(configDirectory: nestedDirectory)
        let state = WorkspaceLayoutState(
            worktreeExplorerWidth: 312,
            fileExplorerWidth: 418
        )

        try nestedStore.save(state)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedStore.layoutFileURL.path))
        XCTAssertEqual(try nestedStore.load(), state)
    }

    func testSaveAtomicallyReplacesPreviousLayout() throws {
        try store.save(
            WorkspaceLayoutState(
                worktreeExplorerWidth: 200,
                fileExplorerWidth: 300
            )
        )
        let replacement = WorkspaceLayoutState(
            worktreeExplorerWidth: 275,
            fileExplorerWidth: 425
        )

        try store.save(replacement)

        XCTAssertEqual(try store.load(), replacement)
    }

    func testInvalidWidthsFallBackToDefaults() throws {
        let state = WorkspaceLayoutState(
            worktreeExplorerWidth: -.infinity,
            fileExplorerWidth: 0
        )
        XCTAssertEqual(
            state.worktreeExplorerWidth,
            WorkspaceLayoutState.defaultWorktreeExplorerWidth
        )
        XCTAssertEqual(
            state.fileExplorerWidth,
            WorkspaceLayoutState.defaultFileExplorerWidth
        )

        let decoded = try JSONDecoder().decode(
            WorkspaceLayoutState.self,
            from: Data(#"{"worktreeExplorerWidth":-10,"fileExplorerWidth":350}"#.utf8)
        )
        XCTAssertEqual(
            decoded.worktreeExplorerWidth,
            WorkspaceLayoutState.defaultWorktreeExplorerWidth
        )
        XCTAssertEqual(decoded.fileExplorerWidth, 350)
    }

    func testValidWidthsAreClampedToPaneConstraints() {
        let state = WorkspaceLayoutState(
            worktreeExplorerWidth: 900,
            fileExplorerWidth: 100
        )

        XCTAssertEqual(state.worktreeExplorerWidth, 480)
        XCTAssertEqual(state.fileExplorerWidth, 190)
    }

    @MainActor
    func testModelLoadsSavedLayoutAndPersistsValidUpdates() throws {
        let initial = WorkspaceLayoutState(
            worktreeExplorerWidth: 310,
            fileExplorerWidth: 410
        )
        try store.save(initial)
        let model = WorkspaceLayoutModel(store: store)

        XCTAssertEqual(model.state, initial)

        model.updateWorktreeExplorerWidth(330)
        model.updateFileExplorerWidth(430)

        XCTAssertEqual(model.worktreeExplorerWidth, 330)
        XCTAssertEqual(model.fileExplorerWidth, 430)
        XCTAssertEqual(
            try store.load(),
            WorkspaceLayoutState(
                worktreeExplorerWidth: 330,
                fileExplorerWidth: 430
            )
        )
    }

    @MainActor
    func testModelUsesDefaultsWhenLayoutIsMissingAndIgnoresInvalidUpdates() throws {
        let model = WorkspaceLayoutModel(store: store)

        XCTAssertEqual(model.state, WorkspaceLayoutState())

        model.updateWorktreeExplorerWidth(.nan)
        model.updateFileExplorerWidth(-1)

        XCTAssertEqual(model.state, WorkspaceLayoutState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.layoutFileURL.path))
    }

    @MainActor
    func testModelUsesLuaFileWidthOnlyWhenLayoutIsMissing() throws {
        let missingLayoutModel = WorkspaceLayoutModel(
            store: store,
            fileExplorerFallbackWidth: 333
        )
        XCTAssertEqual(missingLayoutModel.fileExplorerWidth, 333)

        missingLayoutModel.updateWorktreeExplorerWidth(
            missingLayoutModel.worktreeExplorerWidth
        )
        XCTAssertEqual(try store.load()?.fileExplorerWidth, 333)

        try store.save(
            WorkspaceLayoutState(
                worktreeExplorerWidth: 300,
                fileExplorerWidth: 444
            )
        )
        let persistedLayoutModel = WorkspaceLayoutModel(
            store: store,
            fileExplorerFallbackWidth: 333
        )
        XCTAssertEqual(persistedLayoutModel.fileExplorerWidth, 444)
    }

    @MainActor
    func testModelIgnoresSubToleranceGeometryUpdates() throws {
        let model = WorkspaceLayoutModel(store: store)
        model.updateFileExplorerWidth(320)

        model.updateFileExplorerWidth(320.4)

        XCTAssertEqual(model.fileExplorerWidth, 320)
        XCTAssertEqual(try store.load()?.fileExplorerWidth, 320)
    }

    @MainActor
    func testModelRetriesAnIdenticalUpdateAfterSaveFailure() {
        let failingStore = FailingOnceLayoutStore()
        let model = WorkspaceLayoutModel(store: failingStore)

        model.updateFileExplorerWidth(320)
        XCTAssertEqual(failingStore.saveAttempts, 1)
        XCTAssertNotNil(model.errorMessage)

        model.updateFileExplorerWidth(320)

        XCTAssertEqual(failingStore.saveAttempts, 2)
        XCTAssertEqual(failingStore.savedState?.fileExplorerWidth, 320)
        XCTAssertNil(model.errorMessage)
    }
}
