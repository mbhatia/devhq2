import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import SwiftTreeSitter

@MainActor
final class CorrectedTreeSitterHighlightProvider: HighlightProviding {
    private var language: CodeLanguage = .default
    private var cachedText: String?
    private var cachedHighlights: [HighlightRange] = []

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        language = codeLanguage
        cachedText = nil
        cachedHighlights = []
    }

    func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        cachedText = nil
        completion(.success(IndexSet(integersIn: textView.documentRange)))
    }

    func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        let text = textView.string
        if cachedText != text {
            cachedText = text
            cachedHighlights = Self.highlights(in: text, language: language)
        }
        completion(.success(cachedHighlights.compactMap { highlight in
            guard let intersection = highlight.range.intersection(range) else { return nil }
            return HighlightRange(range: intersection, capture: highlight.capture)
        }))
    }

    static func highlights(in text: String, language: CodeLanguage) -> [HighlightRange] {
        guard let parserLanguage = language.language,
              let query = correctedQuery(for: language, parserLanguage: parserLanguage) else { return [] }

        let parser = Parser()
        do {
            try parser.setLanguage(parserLanguage)
        } catch {
            return []
        }
        guard let tree = parser.parse(text), let root = tree.rootNode else { return [] }

        return Array(query.execute(node: root, in: tree).resolve(with: .init(string: text)))
            .highlights()
            .compactMap { highlight in
                guard let capture = CaptureName.fromString(highlight.name) else { return nil }
                return HighlightRange(range: highlight.range, capture: capture)
            }
    }

    private static func correctedQuery(
        for language: CodeLanguage,
        parserLanguage: Language
    ) -> Query? {
        guard let mainURL = language.queryURL else { return nil }
        var urls = [corrected(mainURL)]
        if let parentURL = language.parentQueryURL {
            urls.append(corrected(parentURL))
        }
        if let additions = language.additionalHighlights {
            urls.append(contentsOf: additions.map {
                corrected(mainURL).deletingLastPathComponent().appendingPathComponent("\($0).scm")
            })
        }

        let source = urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        guard let data = source.data(using: .utf8), !data.isEmpty else { return nil }
        return try? Query(language: parserLanguage, data: data)
    }

    private static func corrected(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path.replacingOccurrences(
            of: "/Resources/Resources/",
            with: "/Resources/"
        ))
    }
}
