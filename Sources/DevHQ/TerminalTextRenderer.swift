import AppKit
import CoreText

/// Core Text row renderer for the terminal grid. Glyph positions are anchored
/// back to Ghostty's cell columns after shaping, so a font's natural advances
/// never determine terminal column geometry.
final class TerminalTextRenderer {
    struct Fonts {
        let regular: NSFont
        let bold: NSFont
        let italic: NSFont
        let boldItalic: NSFont

        func font(for cell: TerminalCell) -> NSFont {
            if cell.bold && cell.italic { return boldItalic }
            if cell.bold { return bold }
            if cell.italic { return italic }
            return regular
        }
    }

    struct CacheStatistics: Equatable {
        let layouts: Int
        let hits: Int
        let misses: Int
    }

    private struct RowKey: Hashable {
        let columns: Int
        let cellWidth: Int
        let fonts: [FontKey]
        let cells: [CellKey]
    }

    private struct FontKey: Hashable {
        let name: String
        let size: Int
    }

    private struct CellKey: Hashable {
        let text: String
        let width: UInt8
        let bold: Bool
        let italic: Bool
    }

    private struct Cluster {
        let run: CTRun
        let glyphRange: CFRange
        let lineAnchor: CGFloat
        let column: Int
    }

    private final class RowLayout {
        // The runs returned by CTLine are borrowed. Keep their owning line alive
        // for as long as this cached layout is drawable.
        let line: CTLine?
        let clusters: [Cluster]
        let utf16Cost: Int
        init(line: CTLine? = nil, clusters: [Cluster], utf16Cost: Int = 0) {
            self.line = line
            self.clusters = clusters
            self.utf16Cost = utf16Cost
        }
    }

    private let maximumCachedRows: Int
    private let maximumCachedUTF16: Int
    private var cache: [RowKey: RowLayout] = [:]
    private var recency: [RowKey] = []
    private var cachedUTF16 = 0
    private var cascadingFonts: [FontKey: CTFont] = [:]
    private var hits = 0
    private var misses = 0

    init(maximumCachedRows: Int = 256, maximumCachedUTF16: Int = 8_192) {
        self.maximumCachedRows = max(1, maximumCachedRows)
        self.maximumCachedUTF16 = max(1, maximumCachedUTF16)
    }

    func invalidate() {
        cache.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
        cascadingFonts.removeAll(keepingCapacity: true)
        cachedUTF16 = 0
    }

    var cacheStatistics: CacheStatistics {
        CacheStatistics(layouts: cache.count, hits: hits, misses: misses)
    }

    /// Draws shaped glyphs only. Backgrounds, selection and cursor remain view
    /// overlays, allowing cursor blinking without reshaping rows.
    func draw(
        row: [TerminalCell],
        fonts: Fonts,
        cellWidth: CGFloat,
        baseline: CGFloat,
        rowOrigin: CGPoint,
        context: CGContext,
        foreground: (Int, TerminalCell) -> NSColor
    ) {
        let layout = layout(for: row, fonts: fonts, cellWidth: cellWidth)
        context.saveGState()
        // AppKit views are flipped. Core Text draws with an upward text space.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = .zero
        for cluster in layout.clusters {
            let cell = row[cluster.column]
            context.setFillColor(foreground(cluster.column, cell).cgColor)
            context.saveGState()
            if mustKeepInkInCell(column: cluster.column, row: row) {
                // Preserve ordinary bearings into blank cells, but do not let a
                // fallback font's natural advance paint over occupied columns.
                context.clip(to: CGRect(
                    x: rowOrigin.x + CGFloat(cluster.column) * cellWidth,
                    y: rowOrigin.y,
                    width: cellWidth * CGFloat(max(1, cell.width)),
                    height: baseline * 2
                ))
            }
            context.translateBy(
                x: rowOrigin.x + CGFloat(cluster.column) * cellWidth - cluster.lineAnchor,
                y: rowOrigin.y + baseline
            )
            // CTRunDraw retains Core Text's color-glyph support (notably emoji),
            // unlike drawing the extracted CGGlyphs with CTFontDrawGlyphs.
            CTRunDraw(cluster.run, context, cluster.glyphRange)
            context.restoreGState()
        }
        context.textPosition = .zero
        context.restoreGState()
    }

    private func mustKeepInkInCell(column: Int, row: [TerminalCell]) -> Bool {
        let isOccupied: (Int) -> Bool = { index in
            row.indices.contains(index) && row[index].width != 0
                && !row[index].text.isEmpty && row[index].text != " "
        }
        return isOccupied(column - 1) || isOccupied(column + Int(max(1, row[column].width)))
    }

    /// Decorations follow grid geometry, rather than font fallback metrics.
    func drawDecorations(
        row: [TerminalCell],
        cellWidth: CGFloat,
        baseline: CGFloat,
        rowOrigin: CGPoint,
        context: CGContext,
        foreground: (Int, TerminalCell) -> NSColor
    ) {
        for (column, cell) in row.enumerated() where cell.width != 0 {
            guard cell.underline || cell.strikethrough || cell.hyperlink != nil else { continue }
            let width = cellWidth * CGFloat(max(1, cell.width))
            context.setStrokeColor(foreground(column, cell).cgColor)
            context.setLineWidth(1)
            if cell.underline || cell.hyperlink != nil {
                let y = rowOrigin.y + baseline + 1
                context.move(to: CGPoint(x: rowOrigin.x + CGFloat(column) * cellWidth, y: y))
                context.addLine(to: CGPoint(x: rowOrigin.x + CGFloat(column) * cellWidth + width, y: y))
                context.strokePath()
            }
            if cell.strikethrough {
                let y = rowOrigin.y + baseline * 0.62
                context.move(to: CGPoint(x: rowOrigin.x + CGFloat(column) * cellWidth, y: y))
                context.addLine(to: CGPoint(x: rowOrigin.x + CGFloat(column) * cellWidth + width, y: y))
                context.strokePath()
            }
        }
    }

    private func layout(for row: [TerminalCell], fonts: Fonts, cellWidth: CGFloat) -> RowLayout {
        let key = RowKey(
            columns: row.count,
            cellWidth: Int((cellWidth * 1024).rounded()),
            fonts: [fonts.regular, fonts.bold, fonts.italic, fonts.boldItalic].map(fontKey),
            cells: row.map { CellKey(text: $0.text, width: $0.width, bold: $0.bold, italic: $0.italic) }
        )
        if let cached = cache[key] {
            hits += 1
            touch(key)
            return cached
        }
        misses += 1
        let attributed = NSMutableAttributedString()
        var utf16ToColumn: [Int] = []
        var columnSourceStarts: [Int: CFIndex] = [:]
        for (column, cell) in row.enumerated() {
            // A width-zero continuation has no independent anchor. Other blank
            // cells must remain in the shaping input: removing them joins text
            // across terminal columns.
            guard cell.width != 0 || !cell.text.isEmpty else { continue }
            let text = cell.text.isEmpty ? " " : cell.text
            let font = cascadingFont(fonts.font(for: cell))
            let start = attributed.length
            columnSourceStarts[column] = CFIndex(start)
            attributed.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .ligature: 0,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
            ]))
            utf16ToColumn.append(contentsOf: repeatElement(column, count: attributed.length - start))
        }
        guard attributed.length > 0 else {
            let empty = RowLayout(clusters: [])
            insert(empty, for: key)
            return empty
        }
        let line = CTLineCreateWithAttributedString(attributed)
        // CTLine string offsets are visual caret offsets in bidi text. Use the
        // base glyph's shaped position instead, then share it with fallback
        // runs for the same terminal cell.
        var columnAnchors: [Int: CGFloat] = [:]
        for runValue in CTLineGetGlyphRuns(line) as NSArray {
            let run = runValue as! CTRun
            let count = CTRunGetGlyphCount(run)
            var positions = Array(repeating: CGPoint.zero, count: count)
            var indices = Array(repeating: CFIndex(), count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            for index in 0..<count {
                let source = Int(indices[index])
                guard utf16ToColumn.indices.contains(source) else { continue }
                let column = utf16ToColumn[source]
                if columnAnchors[column] == nil, columnSourceStarts[column] == indices[index] {
                    columnAnchors[column] = positions[index].x
                }
            }
        }
        var clusters: [Cluster] = []
        for runValue in CTLineGetGlyphRuns(line) as NSArray {
            let run = runValue as! CTRun
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var positions = Array(repeating: CGPoint.zero, count: count)
            var indices = Array(repeating: CFIndex(), count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            var start = 0
            while start < count {
                let sourceIndex = Int(indices[start])
                guard utf16ToColumn.indices.contains(sourceIndex) else { start += 1; continue }
                let column = utf16ToColumn[sourceIndex]
                var end = start + 1
                // A grapheme's combining glyphs can use distinct UTF-16
                // indices. Group all contiguous glyphs anchored to one cell so
                // their shaped offsets remain intact.
                while end < count,
                      utf16ToColumn.indices.contains(Int(indices[end])),
                      utf16ToColumn[Int(indices[end])] == column {
                    end += 1
                }
                clusters.append(Cluster(
                    run: run,
                    glyphRange: CFRange(location: start, length: end - start),
                    lineAnchor: columnAnchors[column] ?? positions[start].x,
                    column: column
                ))
                start = end
            }
        }
        let result = RowLayout(line: line, clusters: clusters, utf16Cost: attributed.length)
        insert(result, for: key)
        return result
    }

    private func fontKey(_ font: NSFont) -> FontKey {
        FontKey(name: font.fontName, size: Int((font.pointSize * 1024).rounded()))
    }

    private func cascadingFont(_ font: NSFont) -> CTFont {
        let key = fontKey(font)
        if let cached = cascadingFonts[key] { return cached }
        guard let symbols = TerminalFont.nerdSymbolsFont(size: font.pointSize) else {
            cascadingFonts[key] = font as CTFont
            return font as CTFont
        }
        let symbolsDescriptor = CTFontCopyFontDescriptor(symbols as CTFont)
        let attributes: [CFString: Any] = [kCTFontCascadeListAttribute: [symbolsDescriptor]]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(font as CTFont), attributes as CFDictionary
        )
        let cascaded = CTFontCreateWithFontDescriptor(descriptor, font.pointSize, nil)
        cascadingFonts[key] = cascaded
        return cascaded
    }

    private func insert(_ layout: RowLayout, for key: RowKey) {
        cache[key] = layout
        recency.append(key)
        cachedUTF16 += layout.utf16Cost
        while recency.count > maximumCachedRows || cachedUTF16 > maximumCachedUTF16 {
            let evicted = recency.removeFirst()
            if let row = cache.removeValue(forKey: evicted) { cachedUTF16 -= row.utf16Cost }
        }
    }

    private func touch(_ key: RowKey) {
        guard let index = recency.firstIndex(of: key) else { return }
        recency.remove(at: index)
        recency.append(key)
    }
}
