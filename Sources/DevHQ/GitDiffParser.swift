import Foundation

/// Parses the single-file unified diffs produced by GitQueryService.
public enum GitDiffParser {
    public static func parse(
        _ data: Data,
        contextID: String,
        fallbackPath: String,
        parentState: GitParentState? = nil
    ) -> GitDiffResult {
        parse(
            String(decoding: data, as: UTF8.self),
            contextID: contextID,
            fallbackPath: fallbackPath,
            parentState: parentState
        )
    }

    public static func parse(
        _ diff: String,
        contextID: String,
        fallbackPath: String,
        parentState: GitParentState? = nil
    ) -> GitDiffResult {
        let rawLines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var metadata: [String] = []
        var parsedHunks: [ParsedHunk] = []
        var currentHunk: ParsedHunk?
        var oldPath: String?
        var newPath = fallbackPath
        var isBinary = false

        func finishHunk() {
            if let currentHunk {
                parsedHunks.append(currentHunk)
            }
            currentHunk = nil
        }

        for (lineIndex, rawLine) in rawLines.enumerated() {
            // split(omittingEmptySubsequences: false) contributes a trailing empty
            // element for the customary final newline. It is not diff content.
            if rawLine.isEmpty, lineIndex == rawLines.indices.last, diff.hasSuffix("\n") {
                continue
            }

            if let header = parseHunkHeader(rawLine) {
                finishHunk()
                currentHunk = ParsedHunk(header: rawLine, range: header, metadata: metadata)
                continue
            }

            if currentHunk != nil {
                currentHunk?.append(rawLine)
                continue
            }

            metadata.append(rawLine)
            updatePaths(
                from: rawLine,
                oldPath: &oldPath,
                newPath: &newPath,
                fallbackPath: fallbackPath
            )
            if rawLine.hasPrefix("Binary files ") || rawLine == "GIT binary patch" {
                isBinary = true
            }
        }
        finishHunk()

        let hunks = parsedHunks.enumerated().map { index, parsed -> GitDiffHunk in
            let id = "\(contextID):\(index)"
            return GitDiffHunk(
                id: id,
                header: parsed.header,
                oldStart: parsed.range.oldStart,
                oldCount: parsed.range.oldCount,
                newStart: parsed.range.newStart,
                newCount: parsed.range.newCount,
                lines: parsed.lines
            )
        }
        let markers = zip(hunks, parsedHunks).flatMap { hunk, parsed in
            makeMarkers(for: parsed, hunkID: hunk.id)
        }

        return GitDiffResult(
            contextID: contextID,
            oldPath: oldPath,
            newPath: newPath,
            hunks: hunks,
            markers: markers,
            parentState: parentState,
            isBinary: isBinary
        )
    }
}

private extension GitDiffParser {
    struct HunkRange {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
    }

    struct ParsedHunk {
        let header: String
        let range: HunkRange
        var lines: [GitDiffLine]
        private var oldLine: Int
        private var newLine: Int

        init(header: String, range: HunkRange, metadata: [String]) {
            self.header = header
            self.range = range
            lines = metadata.map { GitDiffLine(kind: .metadata, text: $0) }
            oldLine = range.oldStart
            newLine = range.newStart
        }

        mutating func append(_ text: String) {
            if text.hasPrefix("+") {
                lines.append(GitDiffLine(kind: .addition, text: text, newLineNumber: newLine))
                newLine += 1
            } else if text.hasPrefix("-") {
                lines.append(GitDiffLine(kind: .deletion, text: text, oldLineNumber: oldLine))
                oldLine += 1
            } else if text.hasPrefix(" ") {
                lines.append(
                    GitDiffLine(
                        kind: .context,
                        text: text,
                        oldLineNumber: oldLine,
                        newLineNumber: newLine
                    )
                )
                oldLine += 1
                newLine += 1
            } else {
                // Includes "\\ No newline at end of file" and any extended
                // headers emitted between semantic lines.
                lines.append(GitDiffLine(kind: .metadata, text: text))
            }
        }
    }

    static func parseHunkHeader(_ line: String) -> HunkRange? {
        guard line.hasPrefix("@@ "),
              let oldMarker = line.firstIndex(of: "-"),
              let plusMarker = line[oldMarker...].firstIndex(of: "+")
        else { return nil }

        let oldTokenStart = line.index(after: oldMarker)
        guard let oldTokenEnd = line[oldTokenStart...].firstIndex(of: " ") else { return nil }
        let newTokenStart = line.index(after: plusMarker)
        guard let newTokenEnd = line[newTokenStart...].firstIndex(of: " "),
              let oldRange = parseRangeToken(line[oldTokenStart..<oldTokenEnd]),
              let newRange = parseRangeToken(line[newTokenStart..<newTokenEnd])
        else { return nil }

        return HunkRange(
            oldStart: oldRange.start,
            oldCount: oldRange.count,
            newStart: newRange.start,
            newCount: newRange.count
        )
    }

    static func parseRangeToken(_ token: Substring) -> (start: Int, count: Int)? {
        let components = token.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(components[0]), components.count <= 2 else { return nil }
        if components.count == 1 {
            return (start, 1)
        }
        guard let count = Int(components[1]) else { return nil }
        return (start, count)
    }

    static func makeMarkers(for hunk: ParsedHunk, hunkID: String) -> [GitDiffMarker] {
        let semanticLines = hunk.lines.filter { $0.kind != .metadata }
        var markers: [GitDiffMarker] = []
        var index = semanticLines.startIndex

        while index < semanticLines.endIndex {
            guard semanticLines[index].kind == .addition || semanticLines[index].kind == .deletion else {
                index += 1
                continue
            }

            let groupStart = index
            while index < semanticLines.endIndex,
                  semanticLines[index].kind == .addition || semanticLines[index].kind == .deletion {
                index += 1
            }
            let group = semanticLines[groupStart..<index]
            let additions = group.compactMap { line -> Int? in
                line.kind == .addition ? line.newLineNumber : nil
            }
            let hasDeletions = group.contains { $0.kind == .deletion }

            if !additions.isEmpty {
                let kind: GitDiffMarkerKind = hasDeletions ? .modified : .added
                markers.append(contentsOf: additions.map {
                    GitDiffMarker(line: max(1, $0), kind: kind, hunkID: hunkID)
                })
            } else if hasDeletions {
                let nextLine = index < semanticLines.endIndex ? semanticLines[index].newLineNumber : nil
                let previousLine = semanticLines[..<groupStart].reversed().compactMap(\.newLineNumber).first
                let anchor = nextLine ?? previousLine ?? max(1, hunk.range.newStart)
                markers.append(GitDiffMarker(line: max(1, anchor), kind: .deleted, hunkID: hunkID))
            }
        }

        return markers
    }

    static func updatePaths(
        from line: String,
        oldPath: inout String?,
        newPath: inout String,
        fallbackPath: String
    ) {
        if line.hasPrefix("diff --git ") {
            let paths = splitGitArguments(String(line.dropFirst("diff --git ".count)))
            if paths.count >= 2 {
                oldPath = normalizedPath(paths[0], stripSidePrefix: true)
                newPath = normalizedPath(paths[1], stripSidePrefix: true) ?? fallbackPath
            }
        } else if line.hasPrefix("rename from ") || line.hasPrefix("copy from ") {
            let prefix = line.hasPrefix("rename from ") ? "rename from " : "copy from "
            oldPath = normalizedPath(String(line.dropFirst(prefix.count)), stripSidePrefix: false)
        } else if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
            let prefix = line.hasPrefix("rename to ") ? "rename to " : "copy to "
            newPath = normalizedPath(String(line.dropFirst(prefix.count)), stripSidePrefix: false) ?? fallbackPath
        } else if line.hasPrefix("--- ") {
            oldPath = normalizedPath(pathHeaderValue(String(line.dropFirst(4))), stripSidePrefix: true)
        } else if line.hasPrefix("+++ ") {
            newPath = normalizedPath(pathHeaderValue(String(line.dropFirst(4))), stripSidePrefix: true) ?? fallbackPath
        }
    }

    static func pathHeaderValue(_ value: String) -> String {
        if value.hasPrefix("\"") { return value }
        return String(value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    static func normalizedPath(_ value: String, stripSidePrefix: Bool) -> String? {
        var path = unquoteGitPath(value)
        guard path != "/dev/null" else { return nil }
        if stripSidePrefix, path.hasPrefix("a/") || path.hasPrefix("b/") {
            path.removeFirst(2)
        }
        return path
    }

    static func splitGitArguments(_ value: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quoted = false
        var escaped = false

        for character in value {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
            } else if character == "\\" && quoted {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character == " " && !quoted {
                if !current.isEmpty {
                    arguments.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { arguments.append(current) }
        return arguments
    }

    static func unquoteGitPath(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        let body = value.dropFirst().dropLast()
        var result = ""
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            guard character == "\\" else {
                result.append(character)
                index = body.index(after: index)
                continue
            }

            index = body.index(after: index)
            guard index < body.endIndex else {
                result.append("\\")
                break
            }
            let escaped = body[index]
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            default: result.append(escaped)
            }
            index = body.index(after: index)
        }
        return result
    }
}
