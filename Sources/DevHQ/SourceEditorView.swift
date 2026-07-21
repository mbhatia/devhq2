import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

struct SourceEditorView: View {
    @Binding var text: String
    let language: CodeLanguage
    let isDark: Bool
    let showGutter: Bool
    let showMinimap: Bool
    let showFoldingRibbon: Bool
    let isEditable: Bool
    let diffConfiguration: DiffEditorConfiguration?

    @State private var state = SourceEditorState()
    @State private var syntaxHighlighter = CorrectedTreeSitterHighlightProvider()
    @StateObject private var diffPresentation = DiffEditorPresentation()

    init(
        text: Binding<String>,
        language: CodeLanguage,
        isDark: Bool,
        showGutter: Bool,
        showMinimap: Bool,
        showFoldingRibbon: Bool,
        isEditable: Bool = true,
        diffConfiguration: DiffEditorConfiguration? = nil
    ) {
        _text = text
        self.language = language
        self.isDark = isDark
        self.showGutter = showGutter
        self.showMinimap = showMinimap
        self.showFoldingRibbon = showFoldingRibbon
        self.isEditable = isEditable
        self.diffConfiguration = diffConfiguration
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SourceEditor(
                $text,
                language: language,
                configuration: Self.configuration(
                    isDark: isDark,
                    showGutter: showGutter,
                    showMinimap: showMinimap,
                    showFoldingRibbon: showFoldingRibbon,
                    isEditable: isEditable
                ),
                state: $state,
                highlightProviders: [syntaxHighlighter],
                coordinators: [diffPresentation.coordinator]
            )

            if diffConfiguration?.isEnabled == true,
               let message = diffPresentation.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .padding(8)
            }
        }
        .task(id: diffLoadIdentity) {
            await diffPresentation.load(diffConfiguration)
        }
        .onDisappear {
            diffPresentation.invalidate()
        }
    }

    private var diffLoadIdentity: DiffLoadIdentity {
        DiffLoadIdentity(
            isEnabled: diffConfiguration?.isEnabled == true,
            context: diffConfiguration?.context
        )
    }

    static func configuration(
        isDark: Bool,
        showGutter: Bool = true,
        showMinimap: Bool = true,
        showFoldingRibbon: Bool = true,
        isEditable: Bool = true
    ) -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: isDark ? .devHQDark : .devHQLight,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                lineHeightMultiple: 1.2,
                wrapLines: false,
                tabWidth: 4
            ),
            behavior: .init(
                isEditable: isEditable,
                indentOption: .spaces(count: 4)
            ),
            layout: .init(editorOverscroll: 0.15),
            peripherals: .init(
                showGutter: showGutter,
                showMinimap: showMinimap,
                showFoldingRibbon: showFoldingRibbon
            )
        )
    }
}

private struct DiffLoadIdentity: Hashable {
    let isEnabled: Bool
    let context: DiffEditorContext?
}

private extension EditorTheme {
    static var devHQLight: EditorTheme {
        EditorTheme(
            text: Attribute(color: NSColor(hex: "202124")),
            insertionPoint: NSColor(hex: "202124"),
            invisibles: Attribute(color: NSColor(hex: "D6D6D6")),
            background: NSColor(hex: "FFFFFF"),
            lineHighlight: NSColor(hex: "ECF5FF"),
            selection: NSColor(hex: "B2D7FF"),
            keywords: Attribute(color: NSColor(hex: "9B2393"), bold: true),
            commands: Attribute(color: NSColor(hex: "326D74")),
            types: Attribute(color: NSColor(hex: "0B4F79")),
            attributes: Attribute(color: NSColor(hex: "815F03")),
            variables: Attribute(color: NSColor(hex: "0F68A0")),
            values: Attribute(color: NSColor(hex: "6C36A9")),
            numbers: Attribute(color: NSColor(hex: "1C00CF")),
            strings: Attribute(color: NSColor(hex: "C41A16")),
            characters: Attribute(color: NSColor(hex: "1C00CF")),
            comments: Attribute(color: NSColor(hex: "267507"))
        )
    }

    static var devHQDark: EditorTheme {
        EditorTheme(
            text: Attribute(color: NSColor(hex: "E7E9EC")),
            insertionPoint: NSColor(hex: "E7E9EC"),
            invisibles: Attribute(color: NSColor(hex: "53606E")),
            background: NSColor(hex: "1E2025"),
            lineHighlight: NSColor(hex: "2F3239"),
            selection: NSColor(hex: "646F83"),
            keywords: Attribute(color: NSColor(hex: "FF7AB2"), bold: true),
            commands: Attribute(color: NSColor(hex: "78C2B3")),
            types: Attribute(color: NSColor(hex: "6BDFFF")),
            attributes: Attribute(color: NSColor(hex: "CC9768")),
            variables: Attribute(color: NSColor(hex: "67B7D1")),
            values: Attribute(color: NSColor(hex: "B281EB")),
            numbers: Attribute(color: NSColor(hex: "D9C97C")),
            strings: Attribute(color: NSColor(hex: "FF8170")),
            characters: Attribute(color: NSColor(hex: "D9C97C")),
            comments: Attribute(color: NSColor(hex: "8A98A8"))
        )
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
