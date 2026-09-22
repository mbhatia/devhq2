import AppKit
import CoreText

/// The terminal uses Ghostty's bundled font defaults independently of the
/// configurable editor font. This also keeps Powerlevel10k and Nerd Font
/// symbols available when a user has not installed a patched font locally.
enum TerminalFont {
    private static let nerdSymbolsPostscriptName = "SymbolsNF"
    private static let bundledFonts = [
        (resourceName: "JetBrainsMono-Regular", postscriptName: "JetBrainsMono-Regular"),
        (resourceName: "JetBrainsMono-Bold", postscriptName: "JetBrainsMono-Bold"),
        (resourceName: "JetBrainsMono-Italic", postscriptName: "JetBrainsMono-Italic"),
        (resourceName: "JetBrainsMono-BoldItalic", postscriptName: "JetBrainsMono-BoldItalic"),
        (resourceName: "SymbolsNerdFont-Regular", postscriptName: nerdSymbolsPostscriptName)
    ]

    static func bundledFontURL(named name: String) -> URL? {
        DevHQResourceBundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
    }

    static func regular(named name: String, size: CGFloat) -> NSFont {
        name.isEmpty
            ? bundled("JetBrainsMono-Regular", size: size, fallback: .regular)
            : EditorFont.monospaced(named: name, size: size, weight: .regular)
    }

    static func bold(named name: String, size: CGFloat) -> NSFont {
        name.isEmpty
            ? bundled("JetBrainsMono-Bold", size: size, fallback: .bold)
            : EditorFont.monospaced(named: name, size: size, weight: .bold)
    }

    static func italic(named name: String, size: CGFloat) -> NSFont {
        guard name.isEmpty else {
            let regular = EditorFont.monospaced(named: name, size: size, weight: .regular)
            return NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
        }
        return bundled("JetBrainsMono-Italic", size: size, fallback: .regular)
    }

    static func boldItalic(named name: String, size: CGFloat) -> NSFont {
        guard name.isEmpty else {
            let bold = EditorFont.monospaced(named: name, size: size, weight: .bold)
            return NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        }
        return bundled("JetBrainsMono-BoldItalic", size: size, fallback: .bold)
    }

    static func font(for text: String, primary: NSFont) -> NSFont {
        guard containsNerdSymbol(in: text),
              !supports(text, in: primary),
              let symbols = nerdSymbolsFont(size: primary.pointSize),
              supports(text, in: symbols) else {
            return primary
        }
        return symbols
    }

    static func nerdSymbolsFont(size: CGFloat) -> NSFont? {
        _ = registerBundledFonts
        return NSFont(name: nerdSymbolsPostscriptName, size: size)
    }

    static func supports(_ text: String, in font: NSFont) -> Bool {
        var characters = Array(text.utf16)
        guard !characters.isEmpty else { return true }
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count)
    }

    /// Registers every terminal font and returns their resolved on-disk URLs.
    /// Used by the packaged-app resource probe before the UI starts.
    static func verifiedBundledFontURLs(in resourceBundle: Bundle) -> [URL]? {
        _ = registerBundledFonts
        var resolvedURLs: [URL] = []
        for font in bundledFonts {
            guard let expectedURL = resourceBundle.url(
                forResource: font.resourceName,
                withExtension: "ttf",
                subdirectory: "Fonts"
            ),
            let resolvedURL = bundledFontURL(named: font.resourceName),
            resolvedURL.standardizedFileURL == expectedURL.standardizedFileURL else {
                return nil
            }
            guard let registeredFont = NSFont(name: font.postscriptName, size: 13),
                  let actualURL = CTFontCopyAttribute(
                    registeredFont as CTFont,
                    kCTFontURLAttribute
                  ) as? URL,
                  actualURL.standardizedFileURL == expectedURL.standardizedFileURL else {
                return nil
            }
            resolvedURLs.append(actualURL)
        }
        return resolvedURLs
    }

    private static func bundled(
        _ postscriptName: String,
        size: CGFloat,
        fallback weight: NSFont.Weight
    ) -> NSFont {
        _ = registerBundledFonts
        return NSFont(name: postscriptName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func containsNerdSymbol(in text: String) -> Bool {
        text.unicodeScalars.contains {
            (0xE000...0xF8FF).contains($0.value) || (0xF0001...0xF1AF0).contains($0.value)
        }
    }

    private static let registerBundledFonts: Void = {
        for font in bundledFonts {
            guard let url = bundledFontURL(named: font.resourceName) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}
