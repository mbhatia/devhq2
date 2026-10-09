import AppKit
import CoreText

/// Resolves the terminal's Ghostty-compatible defaults independently of the editor font.
enum TerminalFont {
    private static let bundledFonts: [(resource: String, postscript: String)] = [
        ("JetBrainsMono-Regular", "JetBrainsMono-Regular"),
        ("JetBrainsMono-Bold", "JetBrainsMono-Bold"),
        ("JetBrainsMono-Italic", "JetBrainsMono-Italic"),
        ("JetBrainsMono-BoldItalic", "JetBrainsMono-BoldItalic"),
        ("SymbolsNerdFont-Regular", "SymbolsNF")
    ]

    static func regular(named name: String, size: CGFloat) -> NSFont {
        name.isEmpty ? bundled("JetBrainsMono-Regular", size: size, fallback: .regular) : EditorFont.monospaced(named: name, size: size, weight: .regular)
    }

    static func bold(named name: String, size: CGFloat) -> NSFont {
        name.isEmpty ? bundled("JetBrainsMono-Bold", size: size, fallback: .bold) : EditorFont.monospaced(named: name, size: size, weight: .bold)
    }

    static func italic(named name: String, size: CGFloat) -> NSFont {
        name.isEmpty ? bundled("JetBrainsMono-Italic", size: size, fallback: .regular) : EditorFont.italic(named: name, size: size, weight: .regular)
    }

    static func boldItalic(named name: String, size: CGFloat) -> NSFont {
        name.isEmpty ? bundled("JetBrainsMono-BoldItalic", size: size, fallback: .bold) : EditorFont.italic(named: name, size: size, weight: .bold)
    }

    /// Returns the Symbols Nerd Font only when `primary` lacks a PUA glyph in this cell.
    /// Keeping this per-cell lets ordinary text retain the configured terminal face.
    static func font(for text: String, primary: NSFont) -> NSFont {
        let privateUseScalars = text.unicodeScalars.filter { isPrivateUse($0.value) }
        guard !privateUseScalars.isEmpty else { return primary }
        let missing = privateUseScalars.filter { !supports($0, in: primary) }
        guard !missing.isEmpty, let symbols = nerdSymbolsFont(size: primary.pointSize),
              missing.allSatisfy({ supports($0, in: symbols) }) else { return primary }
        return symbols
    }

    static func verifiedBundledFontURLs(in resourceBundle: Bundle) -> [URL]? {
        _ = registerBundledFonts
        var urls: [URL] = []
        for font in bundledFonts {
            guard let expected = DevHQResourceBundle.url(in: resourceBundle, forResource: font.resource, withExtension: "ttf", subdirectory: "Fonts"),
                  let resolved = DevHQResourceBundle.url(forResource: font.resource, withExtension: "ttf", subdirectory: "Fonts"),
                  expected.standardizedFileURL == resolved.standardizedFileURL,
                  let registered = NSFont(name: font.postscript, size: 13),
                  let actual = CTFontCopyAttribute(registered as CTFont, kCTFontURLAttribute) as? URL,
                  actual.standardizedFileURL == expected.standardizedFileURL else { return nil }
            urls.append(actual)
        }
        return urls
    }

    private static func bundled(_ postscriptName: String, size: CGFloat, fallback weight: NSFont.Weight) -> NSFont {
        _ = registerBundledFonts
        return NSFont(name: postscriptName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func nerdSymbolsFont(size: CGFloat) -> NSFont? {
        _ = registerBundledFonts
        return NSFont(name: "SymbolsNF", size: size)
    }

    private static func supports(_ scalar: Unicode.Scalar, in font: NSFont) -> Bool {
        var characters = Array(String(scalar).utf16)
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        guard CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count) else { return false }
        // Core Text maps a supplementary scalar on its high surrogate and
        // leaves a zero placeholder for the low surrogate, even on success.
        return glyphs[0] != 0
    }

    private static func isPrivateUse(_ value: UInt32) -> Bool {
        (0xE000...0xF8FF).contains(value) || (0xF0000...0xFFFFD).contains(value) || (0x100000...0x10FFFD).contains(value)
    }

    private static let registerBundledFonts: Void = {
        for font in bundledFonts {
            guard let url = DevHQResourceBundle.url(forResource: font.resource, withExtension: "ttf", subdirectory: "Fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}
