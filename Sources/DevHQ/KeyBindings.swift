import AppKit
import Foundation

struct KeyBinding: Sendable {
    let shortcut: String
    let commandID: String

    fileprivate let key: String
    fileprivate let modifiers: NSEvent.ModifierFlags

    init(shortcut: String, commandID: String) throws {
        guard !commandID.isEmpty else {
            throw KeyBindingError.emptyCommand
        }

        let parsed = try KeyBindingShortcut(shortcut)
        self.shortcut = parsed.canonical
        self.commandID = commandID
        key = parsed.key
        modifiers = parsed.modifiers
    }

    var displayLabel: String {
        KeyBindingShortcut.displayLabel(key: key, modifiers: modifiers)
    }
}

enum KeyBindingError: Error, Equatable, LocalizedError {
    case invalidShortcut(String)
    case shiftedPunctuationShortcut(String)
    case unmodifiedShortcut(String)
    case emptyCommand
    case invalidCommandIdentifier(String)
    case commandNotRegistered(String)
    case conflictingShortcut(shortcut: String, commandID: String)

    var errorDescription: String? {
        switch self {
        case let .invalidShortcut(shortcut):
            "Invalid keybinding shortcut: \(shortcut)"
        case let .shiftedPunctuationShortcut(shortcut):
            "Keybinding shortcut uses shifted punctuation: \(shortcut). Use the base key with shift instead."
        case let .unmodifiedShortcut(shortcut):
            "Keybinding shortcut must include a modifier: \(shortcut)"
        case .emptyCommand:
            "Keybinding command must be a non-empty string."
        case let .invalidCommandIdentifier(commandID):
            "Invalid keybinding command identifier: \(commandID)"
        case let .commandNotRegistered(commandID):
            "Keybinding command is not registered: \(commandID)"
        case let .conflictingShortcut(shortcut, commandID):
            "Keybinding \(shortcut) is already assigned to \(commandID). Pass true as the second argument to keymap.add to overwrite it."
        }
    }
}

private struct KeyBindingShortcut {
    let canonical: String
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(_ shortcut: String) throws {
        let pieces = shortcut.lowercased().split(separator: "+", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty }) else {
            throw KeyBindingError.invalidShortcut(shortcut)
        }

        var modifiers: NSEvent.ModifierFlags = []
        var key: String?
        for piece in pieces {
            switch piece {
            case "cmd", "command":
                guard !modifiers.contains(.command) else { throw KeyBindingError.invalidShortcut(shortcut) }
                modifiers.insert(.command)
            case "ctrl", "control":
                guard !modifiers.contains(.control) else { throw KeyBindingError.invalidShortcut(shortcut) }
                modifiers.insert(.control)
            case "option", "opt", "alt":
                guard !modifiers.contains(.option) else { throw KeyBindingError.invalidShortcut(shortcut) }
                modifiers.insert(.option)
            case "shift":
                guard !modifiers.contains(.shift) else { throw KeyBindingError.invalidShortcut(shortcut) }
                modifiers.insert(.shift)
            default:
                guard key == nil, Self.isSupportedKey(String(piece)) else {
                    throw KeyBindingError.invalidShortcut(shortcut)
                }
                guard !Self.shiftedPunctuation.contains(String(piece)) else {
                    throw KeyBindingError.shiftedPunctuationShortcut(shortcut)
                }
                key = String(piece)
            }
        }

        guard let key else { throw KeyBindingError.invalidShortcut(shortcut) }
        guard !modifiers.isEmpty else { throw KeyBindingError.unmodifiedShortcut(shortcut) }
        self.key = key
        self.modifiers = modifiers
        canonical = Self.canonical(key: key, modifiers: modifiers)
    }

    static func canonical(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var pieces: [String] = []
        if modifiers.contains(.command) { pieces.append("cmd") }
        if modifiers.contains(.control) { pieces.append("ctrl") }
        if modifiers.contains(.option) { pieces.append("option") }
        if modifiers.contains(.shift) { pieces.append("shift") }
        pieces.append(key)
        return pieces.joined(separator: "+")
    }

    static func displayLabel(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        label += displayKeys[key] ?? key.uppercased()
        return label
    }

    static func eventKey(for event: NSEvent) -> String? {
        let keyCode = event.keyCode
        if let special = specialKeysByKeyCode[keyCode] { return special }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else {
            return nil
        }
        return shiftedPunctuationBaseKeys[String(characters)] ?? String(characters)
    }

    private static func isSupportedKey(_ key: String) -> Bool {
        if key.count == 1, key.unicodeScalars.allSatisfy({ scalar in
            scalar.value >= 32 && scalar.value <= 126
        }) {
            return true
        }
        if namedKeys.contains(key) { return true }
        guard key.first == "f", let number = Int(key.dropFirst()) else { return false }
        return (1...20).contains(number)
    }

    private static let namedKeys: Set<String> = [
        "return", "enter", "tab", "space", "escape", "delete", "forwarddelete",
        "up", "down", "left", "right", "home", "end", "pageup", "pagedown"
    ]

    private static let displayKeys: [String: String] = [
        "return": "↩", "enter": "↩", "tab": "⇥", "space": "Space", "escape": "⎋",
        "delete": "⌫", "forwarddelete": "⌦", "up": "↑", "down": "↓", "left": "←",
        "right": "→", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟"
    ]

    private static let specialKeysByKeyCode: [UInt16: String] = [
        36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape", 76: "enter", 117: "forwarddelete",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown", 123: "left", 124: "right",
        125: "down", 126: "up", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5",
        97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20"
    ]

    private static let shiftedPunctuationBaseKeys: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
        "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]",
        "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
    ]

    private static let shiftedPunctuation = Set(shiftedPunctuationBaseKeys.keys)
}

@MainActor
final class KeyBindingRegistry: ObservableObject {
    static let shared = KeyBindingRegistry()

    @Published private(set) var bindings: [KeyBinding] = []
    private var commandIDsByShortcut: [String: String] = [:]
    private var shortcutsByCommandID: [String: Set<String>] = [:]

    func setDefaultBindings(_ bindings: [KeyBinding]) throws {
        try replace(with: bindings)
    }

    func add(_ bindings: [KeyBinding], overwrite: Bool = false) throws {
        var byShortcut = commandIDsByShortcut
        var byCommand = shortcutsByCommandID
        for binding in bindings.sorted(by: {
            $0.shortcut == $1.shortcut ? $0.commandID < $1.commandID : $0.shortcut < $1.shortcut
        }) {
            if let existingCommand = byShortcut[binding.shortcut], existingCommand != binding.commandID {
                guard overwrite else {
                    throw KeyBindingError.conflictingShortcut(shortcut: binding.shortcut, commandID: existingCommand)
                }
                byCommand[existingCommand]?.remove(binding.shortcut)
                if byCommand[existingCommand]?.isEmpty == true {
                    byCommand.removeValue(forKey: existingCommand)
                }
            }
            byShortcut[binding.shortcut] = binding.commandID
            byCommand[binding.commandID, default: []].insert(binding.shortcut)
        }
        apply(byShortcut: byShortcut, byCommand: byCommand)
    }

    func command(for event: NSEvent) -> String? {
        guard let key = KeyBindingShortcut.eventKey(for: event) else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        return commandIDsByShortcut[KeyBindingShortcut.canonical(key: key, modifiers: modifiers)]
    }

    func binding(for commandID: String) -> KeyBinding? {
        guard let shortcut = shortcutsByCommandID[commandID]?.sorted().first else { return nil }
        return bindings.first { $0.shortcut == shortcut }
    }

    func displayLabel(for commandID: String) -> String? {
        guard let shortcuts = shortcutsByCommandID[commandID] else { return nil }
        return shortcuts.sorted().compactMap { shortcut in
            bindings.first { $0.shortcut == shortcut }?.displayLabel
        }.joined(separator: ", ")
    }

    private func replace(with bindings: [KeyBinding]) throws {
        let shortcuts = bindings.map(\.shortcut)
        guard Set(shortcuts).count == shortcuts.count else {
            throw KeyBindingError.invalidShortcut(shortcuts.first ?? "")
        }
        apply(
            byShortcut: Dictionary(uniqueKeysWithValues: bindings.map { ($0.shortcut, $0.commandID) }),
            byCommand: Dictionary(grouping: bindings, by: \.commandID)
                .mapValues { Set($0.map(\.shortcut)) }
        )
    }

    private func apply(byShortcut: [String: String], byCommand: [String: Set<String>]) {
        commandIDsByShortcut = byShortcut
        shortcutsByCommandID = byCommand
        bindings = byShortcut.map { shortcut, commandID in
            // Bindings have already been parsed before entering the registry.
            try! KeyBinding(shortcut: shortcut, commandID: commandID)
        }.sorted { $0.shortcut < $1.shortcut }
    }
}
