import AppKit
import CoreText
import SwiftUI

/// The application-owned typeface used by inherited UI text and default editor
/// and terminal settings. Explicit user font selections remain separate.
enum DevHQFont {
    static let regularPostscriptName = "MartianMonoNFM"
    static let mediumPostscriptName = "MartianMonoNFM-Med"
    static let boldPostscriptName = "MartianMonoNFM-Bold"

    private static let bundledFonts = [
        (resourceName: "MartianMonoNerdFontMono-Regular", postscriptName: regularPostscriptName),
        (resourceName: "MartianMonoNerdFontMono-Medium", postscriptName: mediumPostscriptName),
        (resourceName: "MartianMonoNerdFontMono-Bold", postscriptName: boldPostscriptName)
    ]

    static func bundledFontURL(named name: String) -> URL? {
        DevHQResourceBundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
    }

    static func font(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        let postscriptName: String
        switch weight {
        case .bold, .heavy, .black: postscriptName = boldPostscriptName
        case .medium, .semibold: postscriptName = mediumPostscriptName
        default: postscriptName = regularPostscriptName
        }
        _ = registerBundledFonts
        let base = NSFont(name: postscriptName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        return italic ? syntheticOblique(base) : base
    }

    static func uiFont(named name: String, size: CGFloat = NSFont.systemFontSize) -> Font {
        if !name.isEmpty, let font = NSFont(name: name, size: size) { return Font(font) }
        return Font(font(size: size))
    }

    static func verifiedBundledFontURLs(in resourceBundle: Bundle) -> [URL]? {
        _ = registerBundledFonts
        var resolvedURLs: [URL] = []
        for font in bundledFonts {
            guard let expectedURL = resourceBundle.url(forResource: font.resourceName, withExtension: "ttf", subdirectory: "Fonts"),
                  let resolvedURL = bundledFontURL(named: font.resourceName),
                  resolvedURL.standardizedFileURL == expectedURL.standardizedFileURL,
                  let registeredFont = NSFont(name: font.postscriptName, size: 13),
                  let actualURL = CTFontCopyAttribute(registeredFont as CTFont, kCTFontURLAttribute) as? URL,
                  actualURL.standardizedFileURL == expectedURL.standardizedFileURL else { return nil }
            resolvedURLs.append(actualURL)
        }
        return resolvedURLs
    }

    private static func syntheticOblique(_ font: NSFont) -> NSFont {
        var matrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize, &matrix, nil) as NSFont
    }

    private static let registerBundledFonts: Void = {
        for font in bundledFonts {
            guard let url = bundledFontURL(named: font.resourceName) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}

extension Font {
    static func devHQ(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> Font {
        Font(DevHQFont.font(size: size, weight: weight, italic: italic))
    }

    static func devHQ(_ textStyle: NSFont.TextStyle, weight: NSFont.Weight = .regular, italic: Bool = false) -> Font {
        .devHQ(size: NSFont.preferredFont(forTextStyle: textStyle).pointSize, weight: weight, italic: italic)
    }
}
