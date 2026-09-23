import Foundation

enum TerminalLinkKind: Equatable {
    case url
    case fileURL
    case path
}

struct TerminalLinkMatch: Equatable {
    let kind: TerminalLinkKind
    let target: String
    let line: Int?
    let column: Int?
    let raw: String

    init(kind: TerminalLinkKind, target: String, line: Int? = nil, column: Int? = nil, raw: String) {
        self.kind = kind
        self.target = target
        self.line = line
        self.column = column
        self.raw = raw
    }
}

/// Pattern-matches web and file link candidates in a row of terminal text for
/// Cmd-clicks that hit no OSC 8 hyperlink.
enum TerminalLinkDetector {
    /// Candidate patterns in priority order. The first pattern with a match
    /// whose span contains the clicked column wins.
    private static let patterns: [(kind: TerminalLinkKind, expression: NSRegularExpression)] = [
        (.url, regex(#"https?://[^\s]+"#)),
        (.fileURL, regex(#"file://[^\s]+"#)),
        (.path, regex(#"[\w./~-]+:[0-9]+:[0-9]+"#)),
        (.path, regex(#"[\w./~-]+:[0-9]+"#)),
        (.path, regex(#"/[\w./-]+"#)),
        (.path, regex(#"[\w.-]+/[\w./-]+"#)),
        (.path, regex(#"[\w~-]+(?:\.[\w-]+)+"#))
    ]

    private static let lineColumnSuffixExpression = regex(#"^(.+):([0-9]+):([0-9]+)$"#)
    private static let lineSuffixExpression = regex(#"^(.+):([0-9]+)$"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns above are constants; a failure is a programmer error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    /// Returns the visible text of one terminal row along with the UTF-16
    /// offset of the clicked column, or nil when the click is past the row.
    static func line(
        fromCells cells: [TerminalCell],
        clickedColumn: Int
    ) -> (text: String, utf16Index: Int)? {
        guard cells.indices.contains(clickedColumn) else { return nil }
        var text = ""
        var index = 0
        for (column, cell) in cells.enumerated() {
            if column == clickedColumn { index = text.utf16.count }
            text += cell.text
        }
        return (text, index)
    }

    /// Detects the link candidate whose span contains `utf16Index` in `text`.
    static func detect(in text: String, utf16Index: Int) -> TerminalLinkMatch? {
        guard !text.isEmpty, utf16Index >= 0 else { return nil }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        for (kind, expression) in patterns {
            var detected: TerminalLinkMatch?
            expression.enumerateMatches(in: text, range: fullRange) { result, _, stop in
                guard let range = result?.range,
                      range.location <= utf16Index,
                      utf16Index < range.location + range.length else { return }
                detected = match(kind: kind, raw: nsText.substring(with: range))
                stop.pointee = true
            }
            if let detected { return detected }
        }
        return nil
    }

    private static func match(kind: TerminalLinkKind, raw: String) -> TerminalLinkMatch {
        let trimmed = trimmedTarget(raw)
        if kind != .url, let (path, line, column) = lineAndColumnSuffix(of: trimmed) {
            return TerminalLinkMatch(kind: kind, target: path, line: line, column: column, raw: trimmed)
        }
        if kind == .path, let (path, line) = lineSuffix(of: trimmed) {
            return TerminalLinkMatch(kind: kind, target: path, line: line, raw: trimmed)
        }
        return TerminalLinkMatch(kind: kind, target: trimmed, raw: trimmed)
    }

    /// Drops trailing punctuation and unbalanced closing brackets, matching
    /// how links are usually embedded in prose or diagnostics.
    static func trimmedTarget(_ raw: String) -> String {
        let trailing: Set<Character> = [".", ",", ";", ":"]
        let closing: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        var text = Substring(raw)
        while let last = text.last {
            if trailing.contains(last) {
                text = text.dropLast()
                continue
            }
            if let opening = closing[last] {
                let opens = text.reduce(0) { $1 == opening ? $0 + 1 : $0 }
                let closes = text.reduce(0) { $1 == last ? $0 + 1 : $0 }
                if closes > opens {
                    text = text.dropLast()
                    continue
                }
            }
            break
        }
        return String(text)
    }

    private static func lineAndColumnSuffix(of target: String) -> (String, Int, Int)? {
        let nsTarget = target as NSString
        guard let result = lineColumnSuffixExpression.firstMatch(
            in: target,
            range: NSRange(location: 0, length: nsTarget.length)
        ), let line = Int(nsTarget.substring(with: result.range(at: 2))),
              let column = Int(nsTarget.substring(with: result.range(at: 3))) else { return nil }
        return (nsTarget.substring(with: result.range(at: 1)), line, column)
    }

    private static func lineSuffix(of target: String) -> (String, Int)? {
        let nsTarget = target as NSString
        guard let result = lineSuffixExpression.firstMatch(
            in: target,
            range: NSRange(location: 0, length: nsTarget.length)
        ), let line = Int(nsTarget.substring(with: result.range(at: 2))) else { return nil }
        return (nsTarget.substring(with: result.range(at: 1)), line)
    }

    /// Resolves a detected file target to an absolute path: `file://` targets
    /// are stripped, absolute and `~` paths pass through, and relative paths
    /// resolve against the terminal's working directory, then the worktree root.
    static func resolveFilePath(
        _ target: String,
        currentDirectory: String?,
        workspaceRoot: String?
    ) -> String? {
        guard !target.isEmpty else { return nil }
        var path = target
        if path.hasPrefix("file://") {
            path = String(path.dropFirst("file://".count))
            path = path.removingPercentEncoding ?? path
        }
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("~") { return NSString(string: path).expandingTildeInPath }
        if path.hasPrefix("/") { return path }
        if let currentDirectory, !currentDirectory.isEmpty {
            return currentDirectory + "/" + path
        }
        if let workspaceRoot, !workspaceRoot.isEmpty {
            return workspaceRoot + "/" + path
        }
        return nil
    }
}

enum TerminalLinkRoute: Equatable {
    case editor(path: String, line: Int?, column: Int?)
    case webview(target: String)
    case system(URL)
    case prompt(URL)
    case unhandled
}

/// Decides where a detected terminal link goes, honoring `config.webview`.
enum TerminalLinkRouter {
    static func route(
        _ match: TerminalLinkMatch,
        configuration: WebViewConfiguration,
        currentDirectory: String?,
        workspaceRoot: String?,
        isFile: (String) -> Bool
    ) -> TerminalLinkRoute {
        switch match.kind {
        case .path, .fileURL:
            guard let path = resolvedExistingFile(
                match.target,
                currentDirectory: currentDirectory,
                workspaceRoot: workspaceRoot,
                isFile: isFile
            ) else { return .unhandled }
            return .editor(path: path, line: match.line, column: match.column)
        case .url:
            guard let url = URL(string: match.target),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return .unhandled
            }
            return .prompt(url)
        }
    }

    private static func resolvedExistingFile(
        _ target: String,
        currentDirectory: String?,
        workspaceRoot: String?,
        isFile: (String) -> Bool
    ) -> String? {
        guard !target.isEmpty else { return nil }
        let decoded = target.hasPrefix("file://")
            ? (String(target.dropFirst("file://".count)).removingPercentEncoding ?? String(target.dropFirst("file://".count)))
            : target
        if decoded.hasPrefix("/") || decoded.hasPrefix("~") {
            guard let path = TerminalLinkDetector.resolveFilePath(
                target, currentDirectory: nil, workspaceRoot: nil
            ), isFile(path) else { return nil }
            return path
        }
        let directories = [currentDirectory, workspaceRoot].compactMap { $0 }.filter { !$0.isEmpty }
        for directory in directories {
            let path = directory + "/" + decoded
            if isFile(path) { return path }
        }
        return nil
    }

    static func isHTMLFile(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasSuffix(".html") || lowercased.hasSuffix(".htm")
    }

    static func isLocalhostURL(_ target: String) -> Bool {
        guard let host = URLComponents(string: target)?.host else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }
}
