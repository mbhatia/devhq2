import Foundation

struct WorkspaceLayoutState: Codable, Equatable {
    static let worktreeExplorerWidthRange = 190.0 ... 480.0
    static let fileExplorerWidthRange = 190.0 ... 600.0
    static let defaultWorktreeExplorerWidth = 240.0
    static let defaultFileExplorerWidth = 250.0

    let worktreeExplorerWidth: Double
    let fileExplorerWidth: Double

    init(
        worktreeExplorerWidth: Double = Self.defaultWorktreeExplorerWidth,
        fileExplorerWidth: Double = Self.defaultFileExplorerWidth
    ) {
        self.worktreeExplorerWidth = Self.normalizedWidth(
            worktreeExplorerWidth,
            in: Self.worktreeExplorerWidthRange,
            fallback: Self.defaultWorktreeExplorerWidth
        )
        self.fileExplorerWidth = Self.normalizedWidth(
            fileExplorerWidth,
            in: Self.fileExplorerWidthRange,
            fallback: Self.defaultFileExplorerWidth
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            worktreeExplorerWidth: try container.decode(
                Double.self,
                forKey: .worktreeExplorerWidth
            ),
            fileExplorerWidth: try container.decode(
                Double.self,
                forKey: .fileExplorerWidth
            )
        )
    }

    static func isValidWidth(_ width: Double) -> Bool {
        width.isFinite && width > 0
    }

    private static func normalizedWidth(
        _ width: Double,
        in range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard isValidWidth(width) else { return fallback }
        return min(max(width, range.lowerBound), range.upperBound)
    }
}

protocol WorkspaceLayoutPersisting {
    func load() throws -> WorkspaceLayoutState?
    func save(_ state: WorkspaceLayoutState) throws
}

struct WorkspaceLayoutStateStore: WorkspaceLayoutPersisting {
    let configDirectory: URL

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        configDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.configDirectory = configDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/devhq/ws", isDirectory: true)
        self.fileManager = fileManager
    }

    var layoutFileURL: URL {
        configDirectory.appendingPathComponent("layout.json", isDirectory: false)
    }

    func load() throws -> WorkspaceLayoutState? {
        guard fileManager.fileExists(atPath: layoutFileURL.path) else { return nil }
        return try decoder.decode(
            WorkspaceLayoutState.self,
            from: Data(contentsOf: layoutFileURL)
        )
    }

    func save(_ state: WorkspaceLayoutState) throws {
        try fileManager.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: layoutFileURL, options: .atomic)
    }
}

@MainActor
final class WorkspaceLayoutModel: ObservableObject {
    static let widthUpdateTolerance = 0.5

    @Published private(set) var state: WorkspaceLayoutState
    @Published private(set) var errorMessage: String?

    private let store: any WorkspaceLayoutPersisting
    private var hasPersistedState: Bool

    init(
        store: any WorkspaceLayoutPersisting = WorkspaceLayoutStateStore(),
        fileExplorerFallbackWidth: Double = WorkspaceLayoutState.defaultFileExplorerWidth
    ) {
        self.store = store
        do {
            if let persistedState = try store.load() {
                self.state = persistedState
                self.hasPersistedState = true
            } else {
                self.state = WorkspaceLayoutState(
                    fileExplorerWidth: fileExplorerFallbackWidth
                )
                self.hasPersistedState = false
            }
            self.errorMessage = nil
        } catch {
            self.state = WorkspaceLayoutState(
                fileExplorerWidth: fileExplorerFallbackWidth
            )
            self.hasPersistedState = false
            self.errorMessage = error.localizedDescription
        }
    }

    var worktreeExplorerWidth: Double { state.worktreeExplorerWidth }
    var fileExplorerWidth: Double { state.fileExplorerWidth }

    func updateWorktreeExplorerWidth(_ width: Double) {
        guard WorkspaceLayoutState.isValidWidth(width) else { return }
        update(
            WorkspaceLayoutState(
                worktreeExplorerWidth: width,
                fileExplorerWidth: state.fileExplorerWidth
            )
        )
    }

    func updateFileExplorerWidth(_ width: Double) {
        guard WorkspaceLayoutState.isValidWidth(width) else { return }
        update(
            WorkspaceLayoutState(
                worktreeExplorerWidth: state.worktreeExplorerWidth,
                fileExplorerWidth: width
            )
        )
    }

    private func update(_ updatedState: WorkspaceLayoutState) {
        let widthChanged = abs(
            updatedState.worktreeExplorerWidth - state.worktreeExplorerWidth
        ) >= Self.widthUpdateTolerance || abs(
            updatedState.fileExplorerWidth - state.fileExplorerWidth
        ) >= Self.widthUpdateTolerance
        guard widthChanged || !hasPersistedState else { return }
        state = updatedState
        do {
            try store.save(updatedState)
            hasPersistedState = true
            errorMessage = nil
        } catch {
            hasPersistedState = false
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
