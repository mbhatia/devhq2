import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

/// A one-shot request to move the editor caret to a 1-indexed line and column.
struct EditorCursorRequest: Equatable {
    let line: Int
    let column: Int
    private let requestID = UUID()

    init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

struct SourceEditorView: View {
    @Binding var text: String
    let language: CodeLanguage
    let isDark: Bool
    let showGutter: Bool
    let showMinimap: Bool
    let showFoldingRibbon: Bool
    let fontName: String
    let isEditable: Bool
    let diffConfiguration: DiffEditorConfiguration?
    let cursorRequest: EditorCursorRequest?
    let onCursorRequestHandled: (() -> Void)?
    let commentContext: CommentEditorContext?

    @State private var state = SourceEditorState()
    @State private var syntaxHighlighter = CorrectedTreeSitterHighlightProvider()
    @StateObject private var diffPresentation = DiffEditorPresentation()
    @StateObject private var cursorCoordinator = EditorCursorCoordinator()
    @StateObject private var commentPresentation = CommentEditorPresentation()

    init(
        text: Binding<String>,
        language: CodeLanguage,
        isDark: Bool,
        showGutter: Bool,
        showMinimap: Bool,
        showFoldingRibbon: Bool,
        fontName: String,
        isEditable: Bool = true,
        diffConfiguration: DiffEditorConfiguration? = nil,
        cursorRequest: EditorCursorRequest? = nil,
        onCursorRequestHandled: (() -> Void)? = nil,
        commentContext: CommentEditorContext? = nil
    ) {
        _text = text
        self.language = language
        self.isDark = isDark
        self.showGutter = showGutter
        self.showMinimap = showMinimap
        self.showFoldingRibbon = showFoldingRibbon
        self.fontName = fontName
        self.isEditable = isEditable
        self.diffConfiguration = diffConfiguration
        self.cursorRequest = cursorRequest
        self.onCursorRequestHandled = onCursorRequestHandled
        self.commentContext = commentContext
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
                    fontName: fontName,
                    isEditable: isEditable
                ),
                state: $state,
                highlightProviders: [syntaxHighlighter],
                coordinators: [
                    diffPresentation.coordinator,
                    cursorCoordinator,
                    commentPresentation.coordinator
                ]
            )

            if diffConfiguration?.isEnabled == true,
               let message = diffPresentation.statusMessage {
                Text(message)
                    .font(.ui(.caption1))
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
        .onAppear {
            cursorCoordinator.apply(cursorRequest, onHandled: onCursorRequestHandled)
        }
        .onChange(of: cursorRequest) { request in
            cursorCoordinator.apply(request, onHandled: onCursorRequestHandled)
        }
        .task(id: commentContext) {
            commentPresentation.bind(context: commentContext)
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
        fontName: String = "",
        isEditable: Bool = true
    ) -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: isDark ? .devHQDark : .devHQLight,
                font: EditorFont.monospaced(named: fontName, size: 13, weight: .regular),
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

/// Applies caret jump requests (e.g. terminal path:line:col links) once the
/// editor's text controller is on screen.
@MainActor
final class EditorCursorCoordinator: NSObject, ObservableObject, @preconcurrency TextViewCoordinator {
    private weak var controller: TextViewController?
    private var hasAppeared = false
    private var pending: (request: EditorCursorRequest, onHandled: (() -> Void)?)?
    private var lastAppliedRequest: EditorCursorRequest?

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
    }

    func controllerDidAppear(controller: TextViewController) {
        hasAppeared = true
        if let pending {
            self.pending = nil
            apply(pending.request, onHandled: pending.onHandled)
        }
    }

    func destroy() {
        controller = nil
        hasAppeared = false
        pending = nil
    }

    func apply(_ request: EditorCursorRequest?, onHandled: (() -> Void)?) {
        guard let request, request != lastAppliedRequest else { return }
        guard let controller, hasAppeared else {
            pending = (request, onHandled)
            return
        }
        lastAppliedRequest = request
        controller.setCursorPositions(
            [CursorPosition(line: request.line, column: request.column)],
            scrollToVisible: true
        )
        onHandled?()
    }
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
