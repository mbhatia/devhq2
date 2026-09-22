import AppKit

enum EditorFont {
    static func monospaced(named name: String, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        guard !name.isEmpty, let font = NSFont(name: name, size: size) else {
            return DevHQFont.font(size: size, weight: weight)
        }
        guard weight == .regular else {
            return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        return font
    }

    static func italic(named name: String, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let font = monospaced(named: name, size: size, weight: weight)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        return italic == font ? DevHQFont.font(size: size, weight: weight, italic: true) : italic
    }
}
