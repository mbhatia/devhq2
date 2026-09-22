import AppKit

/// Resolves terminal font overrides, otherwise using bundled Martian Mono.
enum TerminalFont {
    static func regular(named name: String, size: CGFloat) -> NSFont {
        name.isEmpty ? DevHQFont.font(size: size) : EditorFont.monospaced(named: name, size: size, weight: .regular)
    }

    static func bold(named name: String, size: CGFloat) -> NSFont {
        name.isEmpty ? DevHQFont.font(size: size, weight: .bold) : EditorFont.monospaced(named: name, size: size, weight: .bold)
    }

    static func italic(named name: String, size: CGFloat) -> NSFont {
        name.isEmpty ? DevHQFont.font(size: size, italic: true) : EditorFont.italic(named: name, size: size, weight: .regular)
    }

    static func boldItalic(named name: String, size: CGFloat) -> NSFont {
        name.isEmpty ? DevHQFont.font(size: size, weight: .bold, italic: true) : EditorFont.italic(named: name, size: size, weight: .bold)
    }

    static func verifiedBundledFontURLs(in resourceBundle: Bundle) -> [URL]? {
        DevHQFont.verifiedBundledFontURLs(in: resourceBundle)
    }
}
