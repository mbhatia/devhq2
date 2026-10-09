import AppKit
import CoreText

/// Ghostty rounds the grid in backing pixels, not independently in view points.
struct TerminalFontMetrics {
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let baseline: CGFloat

    init(font: NSFont, scale: CGFloat) {
        let scale = max(1, scale)
        let face = CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize * scale, nil, nil)
        var characters = Array(UInt16(32)...UInt16(126))
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        var advances = Array(repeating: CGSize.zero, count: characters.count)
        CTFontGetGlyphsForCharacters(face, &characters, &glyphs, characters.count)
        CTFontGetAdvancesForGlyphs(face, .horizontal, &glyphs, &advances, glyphs.count)

        let ascent = CTFontGetAscent(face)
        let descent = CTFontGetDescent(face)
        let leading = CTFontGetLeading(face)
        let faceHeight = ascent + descent + leading
        let height = max(1, faceHeight.rounded())
        let bottomBaseline = (leading / 2 + descent - (height - faceHeight) / 2).rounded()
        cellWidth = max(1, (advances.map(\.width).max() ?? 1).rounded()) / scale
        cellHeight = height / scale
        baseline = (height - bottomBaseline) / scale
    }
}
