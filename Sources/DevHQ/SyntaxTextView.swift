import AppKit
import CodeEditLanguages
import SwiftTreeSitter
import SwiftUI

struct SyntaxTextView: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
    let isDark: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.string = text
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.highlight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxTextView
        weak var textView: NSTextView?
        private var isHighlighting = false

        init(parent: SyntaxTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !isHighlighting else { return }
            parent.text = textView.string
            highlight()
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage, !isHighlighting else { return }
            isHighlighting = true
            defer { isHighlighting = false }

            let text = textView.string
            let range = NSRange(location: 0, length: (text as NSString).length)
            let palette = Palette(isDark: parent.isDark)
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let selection = textView.selectedRanges

            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: palette.text], range: range)
            textView.backgroundColor = palette.background
            textView.insertionPointColor = palette.text

            for highlight in TreeSitterHighlighter.tokens(in: text, language: parent.language)
                where NSMaxRange(highlight.range) <= storage.length {
                storage.addAttributes(
                    attributes(for: highlight.name, palette: palette, font: font),
                    range: highlight.range
                )
            }
            storage.endEditing()
            textView.selectedRanges = selection
        }

        private func attributes(
            for capture: String,
            palette: Palette,
            font: NSFont
        ) -> [NSAttributedString.Key: Any] {
            let root = capture.split(separator: ".").first.map(String.init) ?? capture
            let color: NSColor
            switch root {
            case "comment": color = palette.comment
            case "string", "character": color = palette.string
            case "number", "float": color = palette.number
            case "type", "constructor": color = palette.type
            case "function", "method": color = palette.function
            case "property", "variable", "parameter": color = palette.variable
            case "constant", "boolean": color = palette.constant
            case "attribute": color = palette.attribute
            case "keyword", "operator": color = palette.keyword
            default: color = palette.text
            }
            let styledFont = root == "keyword"
                ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                : font
            return [.foregroundColor: color, .font: styledFont]
        }
    }
}

struct SyntaxToken: Equatable {
    let name: String
    let range: NSRange
}

enum TreeSitterHighlighter {
    private static var queryCache: [TreeSitterLanguage: Query] = [:]

    static func tokens(in text: String, language: CodeLanguage) -> [SyntaxToken] {
        guard let parserLanguage = language.language,
              let query = query(for: language, parserLanguage: parserLanguage) else { return [] }
        let parser = Parser()
        do {
            try parser.setLanguage(parserLanguage)
        } catch {
            return []
        }
        guard let tree = parser.parse(text), let root = tree.rootNode else { return [] }
        let cursor = query.execute(node: root, in: tree)
        return Array(cursor.resolve(with: .init(string: text))).highlights().map {
            SyntaxToken(name: $0.name, range: $0.range)
        }
    }

    private static func query(for language: CodeLanguage, parserLanguage: Language) -> Query? {
        if let cached = queryCache[language.id] {
            return cached
        }
        if let query = TreeSitterModel.shared.query(for: language.id) {
            queryCache[language.id] = query
            return query
        }

        // CodeEditLanguages 0.1.20 duplicates "Resources" in SwiftPM query URLs.
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
        guard let query = try? Query(language: parserLanguage, data: data) else { return nil }
        queryCache[language.id] = query
        return query
    }

    private static func corrected(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path.replacingOccurrences(
            of: "/Resources/Resources/",
            with: "/Resources/"
        ))
    }
}

private struct Palette {
    let background: NSColor
    let text: NSColor
    let keyword: NSColor
    let type: NSColor
    let function: NSColor
    let variable: NSColor
    let constant: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor
    let attribute: NSColor

    init(isDark: Bool) {
        background = NSColor(hex: isDark ? "1E2025" : "FFFFFF")
        text = NSColor(hex: isDark ? "E7E9EC" : "202124")
        keyword = NSColor(hex: isDark ? "FF7AB2" : "9B2393")
        type = NSColor(hex: isDark ? "6BDFFF" : "0B4F79")
        function = NSColor(hex: isDark ? "78C2B3" : "326D74")
        variable = NSColor(hex: isDark ? "67B7D1" : "0F68A0")
        constant = NSColor(hex: isDark ? "B281EB" : "6C36A9")
        string = NSColor(hex: isDark ? "FF8170" : "C41A16")
        number = NSColor(hex: isDark ? "D9C97C" : "1C00CF")
        comment = NSColor(hex: isDark ? "8A98A8" : "267507")
        attribute = NSColor(hex: isDark ? "CC9768" : "815F03")
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
