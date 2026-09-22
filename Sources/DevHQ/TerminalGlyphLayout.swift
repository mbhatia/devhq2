import CoreGraphics

/// Applies the small subset of Ghostty's Nerd Font constraints used by the
/// bundled symbol font. Powerline glyphs deliberately remain unmodified: they
/// have separate stretch rules in Ghostty.
enum TerminalGlyphLayout {
    static func isConstrainedNerdIcon(_ text: String) -> Bool {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 0xE700...0xE8EF, 0xF000...0xF381, 0xF400...0xF533, 0xF0001...0xF1AF0:
            return true
        default:
            return false
        }
    }

    /// Ghostty's `fit_cover1` behavior for the generated Nerd Font rules.
    /// A following blank cell may offer two-cell clipping room, but icons are
    /// never enlarged just because that room exists.
    static func layout(
        glyphBounds: CGRect,
        cellRect: CGRect,
        faceRect: CGRect,
        faceWidth: CGFloat,
        availableCells: Int,
        singleIconHeight: CGFloat,
        iconHeight: CGFloat
    ) -> Layout? {
        guard glyphBounds.width > 0, glyphBounds.height > 0,
              cellRect.width > 0, faceRect.height > 0, faceWidth > 0,
              singleIconHeight > 0, iconHeight > 0 else { return nil }

        let cells = min(max(availableCells, 1), 2)
        let singleScale = min(faceWidth / glyphBounds.width, singleIconHeight / glyphBounds.height)
        let availableWidth = faceWidth * CGFloat(cells)
        let targetHeight = cells == 1 ? singleIconHeight : iconHeight
        let fitScale = min(availableWidth / glyphBounds.width, targetHeight / glyphBounds.height)
        let scale = cells == 2 && fitScale > 1 ? max(1, singleScale) : fitScale

        let size = CGSize(width: glyphBounds.width * scale, height: glyphBounds.height * scale)
        // `center1` centers relative to the first cell, clamping to its left
        // edge when a two-cell glyph is wider than one cell.
        let inkX = cellRect.minX + max(0, (cellRect.width - size.width) / 2)
        let inkY = faceRect.minY + (faceRect.height - size.height) / 2
        return Layout(
            scale: scale,
            origin: CGPoint(x: inkX - glyphBounds.minX * scale, y: inkY - glyphBounds.minY * scale),
            inkRect: CGRect(origin: CGPoint(x: inkX, y: inkY), size: size)
        )
    }

    struct Layout {
        let scale: CGFloat
        let origin: CGPoint
        let inkRect: CGRect
    }
}
