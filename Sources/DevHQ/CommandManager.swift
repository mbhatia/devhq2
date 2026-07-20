import Foundation

enum CommandViewKind: String, CaseIterable, Hashable {
    case worktree
    case file
    case document
}

struct CommandContext: Equatable {
    let view: CommandViewKind
    let worktreeURL: URL?
    let fileURL: URL?
    let documentURL: URL?

    init(
        view: CommandViewKind,
        worktreeURL: URL? = nil,
        fileURL: URL? = nil,
        documentURL: URL? = nil
    ) {
        self.view = view
        self.worktreeURL = worktreeURL
        self.fileURL = fileURL
        self.documentURL = documentURL
    }
}

enum CommandManagerError: Error, Equatable, LocalizedError {
    case invalidIdentifier(String)
    case commandNotFound(String)
    case commandOutOfScope(id: String, view: CommandViewKind)
    case commandUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let id):
            "Invalid command identifier: \(id)"
        case .commandNotFound(let id):
            "Command not found: \(id)"
        case .commandOutOfScope(let id, let view):
            "Command \(id) is not available in the \(view.rawValue) view."
        case .commandUnavailable(let id):
            "Command is currently unavailable: \(id)"
        }
    }
}

struct RegisteredCommand: Identifiable {
    typealias Predicate = (CommandContext) throws -> Bool
    typealias Action = (CommandContext) throws -> Void

    let id: String
    let viewKinds: Set<CommandViewKind>
    let predicate: Predicate
    let action: Action

    var title: String {
        Self.title(for: id)
    }

    init(
        id: String,
        viewKinds: Set<CommandViewKind>,
        predicate: @escaping Predicate = { _ in true },
        action: @escaping Action
    ) throws {
        guard Self.isValidIdentifier(id) else {
            throw CommandManagerError.invalidIdentifier(id)
        }
        self.id = id
        self.viewKinds = viewKinds
        self.predicate = predicate
        self.action = action
    }

    static func isValidIdentifier(_ id: String) -> Bool {
        let segments = id.split(separator: ":", omittingEmptySubsequences: false)
        guard segments.count == 2 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.utf8.allSatisfy { character in
                (97...122).contains(character)
                    || (48...57).contains(character)
                    || character == 46
                    || character == 45
            }
        }
    }

    static func title(for id: String) -> String {
        id.replacingOccurrences(of: ":", with: ": ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

struct CommandPredicateFailure {
    let commandID: String
    let error: any Error
}

struct CommandListing {
    let commands: [RegisteredCommand]
    let predicateFailures: [CommandPredicateFailure]
}

@MainActor
final class CommandManager: ObservableObject {
    @Published private(set) var commandsByID: [String: RegisteredCommand] = [:]

    @discardableResult
    func add(
        id: String,
        viewKinds: Set<CommandViewKind>,
        predicate: @escaping RegisteredCommand.Predicate = { _ in true },
        action: @escaping RegisteredCommand.Action
    ) throws -> RegisteredCommand? {
        let command = try RegisteredCommand(
            id: id,
            viewKinds: viewKinds,
            predicate: predicate,
            action: action
        )
        return commandsByID.updateValue(command, forKey: id)
    }

    @discardableResult
    func remove(id: String) -> Bool {
        commandsByID.removeValue(forKey: id) != nil
    }

    func commands(in context: CommandContext) throws -> [RegisteredCommand] {
        try sorted(
            commandsByID.values
            .filter { command in
                guard command.viewKinds.contains(context.view) else { return false }
                return try command.predicate(context)
            }
        )
    }

    func commandListing(in context: CommandContext) -> CommandListing {
        var commands: [RegisteredCommand] = []
        var predicateFailures: [CommandPredicateFailure] = []

        for command in commandsByID.values where command.viewKinds.contains(context.view) {
            do {
                if try command.predicate(context) {
                    commands.append(command)
                }
            } catch {
                predicateFailures.append(
                    CommandPredicateFailure(commandID: command.id, error: error)
                )
            }
        }

        return CommandListing(
            commands: sorted(commands),
            predicateFailures: predicateFailures.sorted { $0.commandID < $1.commandID }
        )
    }

    func execute(id: String, in context: CommandContext) throws {
        guard let command = commandsByID[id] else {
            throw CommandManagerError.commandNotFound(id)
        }
        guard command.viewKinds.contains(context.view) else {
            throw CommandManagerError.commandOutOfScope(id: id, view: context.view)
        }
        guard try command.predicate(context) else {
            throw CommandManagerError.commandUnavailable(id)
        }
        try command.action(context)
    }

    private func sorted<S: Sequence>(_ commands: S) -> [RegisteredCommand]
    where S.Element == RegisteredCommand {
        commands.sorted { lhs, rhs in
            if lhs.title == rhs.title {
                return lhs.id < rhs.id
            }
            return lhs.title < rhs.title
        }
    }
}
