import AppKit
import CoreGraphics
import XCTest
@testable import DevHQ

@MainActor
final class TerminalTextRendererTests: XCTestCase {
    private let cellWidth: CGFloat = 18
    private let baseline: CGFloat = 20
    private let background = (red: UInt8(12), green: UInt8(15), blue: UInt8(20))

    func testDrawsColoredGlyphIntoOffscreenBitmap() throws {
        let bitmap = try makeBitmap(width: 48, height: 32)
        let renderer = TerminalTextRenderer()
        let row = [TerminalCell(text: "A", foreground: TerminalRGB(red: 230, green: 24, blue: 24))]

        fillBackground(bitmap.context, width: 48, height: 32)
        renderer.draw(
            row: row,
            fonts: fonts,
            cellWidth: cellWidth,
            baseline: baseline,
            rowOrigin: .zero,
            context: bitmap.context,
            foreground: { _, cell in cell.foreground?.nsColor ?? .textColor }
        )

        let glyphPixels = pixels(in: bitmap).filter { pixel in
            pixel.red != background.red || pixel.green != background.green || pixel.blue != background.blue
        }
        XCTAssertFalse(glyphPixels.isEmpty, "The Core Text draw should change the bitmap.")
        XCTAssertTrue(glyphPixels.contains { $0.red > $0.green + 40 && $0.red > $0.blue + 40 },
                      "Glyph pixels should retain the requested red foreground color.")
    }

    func testCombiningAndWideEmojiDrawAndReuseCachedLayout() throws {
        let bitmap = try makeBitmap(width: 96, height: 32)
        let renderer = TerminalTextRenderer()
        let row = [
            TerminalCell(text: "e\u{0301}", width: 1),
            TerminalCell(text: "👩🏽‍💻", width: 2),
            TerminalCell(text: " ", width: 0),
            TerminalCell(text: "x", width: 1)
        ]

        fillBackground(bitmap.context, width: 96, height: 32)
        draw(row, with: renderer, in: bitmap.context)
        XCTAssertGreaterThan(inkPixelCount(in: bitmap, columns: 0..<1), 0,
                             "The combining grapheme should ink its terminal cell.")
        XCTAssertGreaterThan(inkPixelCount(in: bitmap, columns: 1..<3), 0,
                             "The wide emoji should ink its two-cell terminal span.")
        XCTAssertTrue(hasNonMonochromeInk(in: bitmap, columns: 1..<3),
                      "Apple Color Emoji should retain color through CTRunDraw.")
        XCTAssertGreaterThan(inkPixelCount(in: bitmap, columns: 3..<4), 0,
                             "The ASCII cell after a width-zero continuation must retain its column anchor.")
        let statisticsAfterFirstDraw = renderer.cacheStatistics

        draw(row, with: renderer, in: bitmap.context)
        let statisticsAfterSecondDraw = renderer.cacheStatistics
        XCTAssertGreaterThan(statisticsAfterSecondDraw.hits, statisticsAfterFirstDraw.hits)
        XCTAssertEqual(statisticsAfterSecondDraw.layouts, 1)
    }

    func testFontSizeChangeCreatesDistinctCachedLayout() throws {
        let bitmap = try makeBitmap(width: 48, height: 32)
        let renderer = TerminalTextRenderer()
        let row = [TerminalCell(text: "A")]

        renderer.draw(row: row, fonts: fonts(ofSize: 18), cellWidth: cellWidth, baseline: baseline,
                      rowOrigin: .zero, context: bitmap.context, foreground: { _, _ in .white })
        let firstDraw = renderer.cacheStatistics
        renderer.draw(row: row, fonts: fonts(ofSize: 20), cellWidth: cellWidth, baseline: baseline,
                      rowOrigin: .zero, context: bitmap.context, foreground: { _, _ in .white })

        XCTAssertGreaterThan(renderer.cacheStatistics.misses, firstDraw.misses)
        XCTAssertEqual(renderer.cacheStatistics.layouts, 2)
    }

    func testSyntheticItalicCreatesDistinctCachedLayout() throws {
        let bitmap = try makeBitmap(width: 48, height: 32)
        let renderer = TerminalTextRenderer()
        let row = [TerminalCell(text: "A")]
        let regular = TerminalFont.regular(named: "", size: 18)
        let italic = TerminalFont.italic(named: "", size: 18)

        renderer.draw(row: row, fonts: .init(regular: regular, bold: regular, italic: regular, boldItalic: regular),
                      cellWidth: cellWidth, baseline: baseline, rowOrigin: .zero, context: bitmap.context,
                      foreground: { _, _ in .white })
        renderer.draw(row: row, fonts: .init(regular: italic, bold: italic, italic: italic, boldItalic: italic),
                      cellWidth: cellWidth, baseline: baseline, rowOrigin: .zero, context: bitmap.context,
                      foreground: { _, _ in .white })

        XCTAssertEqual(renderer.cacheStatistics.layouts, 2)
    }

    func testForegroundAndSelectionStyleChangesReuseCachedLayout() throws {
        let bitmap = try makeBitmap(width: 48, height: 32)
        let renderer = TerminalTextRenderer()
        let row = [TerminalCell(text: "A")]

        // Selection is an overlay concern. Changing its foreground treatment
        // must not reshape an otherwise identical terminal row.
        renderer.draw(row: row, fonts: fonts, cellWidth: cellWidth, baseline: baseline,
                      rowOrigin: .zero, context: bitmap.context, foreground: { _, _ in .white })
        let firstDraw = renderer.cacheStatistics
        renderer.draw(row: row, fonts: fonts, cellWidth: cellWidth, baseline: baseline,
                      rowOrigin: .zero, context: bitmap.context,
                      foreground: { _, _ in NSColor(calibratedRed: 0.2, green: 0.6, blue: 1, alpha: 1) })

        XCTAssertGreaterThan(renderer.cacheStatistics.hits, firstDraw.hits)
        XCTAssertEqual(renderer.cacheStatistics.layouts, 1)
    }

    func testDrawResetsAStaleTextPositionBeforeDrawing() throws {
        let bitmap = try makeBitmap(width: 48, height: 32)
        let renderer = TerminalTextRenderer()
        fillBackground(bitmap.context, width: 48, height: 32)
        bitmap.context.textPosition = CGPoint(x: 500, y: 500)

        draw([TerminalCell(text: "A")], with: renderer, in: bitmap.context)

        XCTAssertGreaterThan(inkPixelCount(in: bitmap, columns: 0..<1), 0,
                             "A stale Core Graphics text position must not offset terminal glyphs.")
    }

    func testCacheEvictsForBothCapsAndInvalidateClearsLayouts() throws {
        let rowCapRenderer = TerminalTextRenderer(maximumCachedRows: 2, maximumCachedUTF16: 100)
        let bitmap = try makeBitmap(width: 64, height: 32)
        for text in ["a", "b", "c"] {
            draw([TerminalCell(text: text)], with: rowCapRenderer, in: bitmap.context)
        }
        XCTAssertEqual(rowCapRenderer.cacheStatistics.layouts, 2)

        let utf16CapRenderer = TerminalTextRenderer(maximumCachedRows: 10, maximumCachedUTF16: 3)
        draw([TerminalCell(text: "ab")], with: utf16CapRenderer, in: bitmap.context)
        draw([TerminalCell(text: "cd")], with: utf16CapRenderer, in: bitmap.context)
        XCTAssertEqual(utf16CapRenderer.cacheStatistics.layouts, 1)
        let beforeRepeat = utf16CapRenderer.cacheStatistics.hits
        draw([TerminalCell(text: "cd")], with: utf16CapRenderer, in: bitmap.context)
        XCTAssertGreaterThan(utf16CapRenderer.cacheStatistics.hits, beforeRepeat)

        rowCapRenderer.invalidate()
        XCTAssertEqual(rowCapRenderer.cacheStatistics.layouts, 0)
    }

    func testRTLArabicRowDrawsAndCachesUsingTerminalSourceOrderAnchors() throws {
        let bitmap = try makeBitmap(width: 128, height: 32)
        let renderer = TerminalTextRenderer()
        // Terminal cells remain in source-column order even when Core Text's
        // bidi shaping presents these Arabic glyphs right-to-left. The renderer
        // anchors each shaped cluster to that source terminal column.
        let row = ["A", "م", "ر", "ح", "ب", "ا", "Z"].map { TerminalCell(text: $0) }

        fillBackground(bitmap.context, width: 128, height: 32)
        draw(row, with: renderer, in: bitmap.context)
        XCTAssertGreaterThan(inkPixelCount(in: bitmap, columns: 0..<1), 0)
        XCTAssertGreaterThan(inkPixelCount(in: bitmap, columns: 1..<6), 0)
        XCTAssertGreaterThan(inkPixelCount(in: bitmap, columns: 6..<7), 0,
                             "The trailing source-order terminal cell should remain at column six.")
        let firstDraw = renderer.cacheStatistics

        draw(row, with: renderer, in: bitmap.context)
        XCTAssertGreaterThan(renderer.cacheStatistics.hits, firstDraw.hits)
        XCTAssertEqual(renderer.cacheStatistics.layouts, 1)
    }

    private var fonts: TerminalTextRenderer.Fonts { fonts(ofSize: 18) }

    private func fonts(ofSize size: CGFloat) -> TerminalTextRenderer.Fonts {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return TerminalTextRenderer.Fonts(regular: font, bold: font, italic: font, boldItalic: font)
    }

    private func draw(_ row: [TerminalCell], with renderer: TerminalTextRenderer, in context: CGContext) {
        renderer.draw(
            row: row,
            fonts: fonts,
            cellWidth: cellWidth,
            baseline: baseline,
            rowOrigin: .zero,
            context: context,
            foreground: { _, cell in cell.foreground?.nsColor ?? .white }
        )
    }

    private func makeBitmap(width: Int, height: Int) throws -> Bitmap {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        // Match NativeTerminalView's flipped AppKit coordinate space.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return Bitmap(context: context, width: width, height: height)
    }

    private func fillBackground(_ context: CGContext, width: Int, height: Int) {
        context.setFillColor(
            red: CGFloat(background.red) / 255,
            green: CGFloat(background.green) / 255,
            blue: CGFloat(background.blue) / 255,
            alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func inkPixelCount(in bitmap: Bitmap, columns: Range<Int>) -> Int {
        pixels(in: bitmap).enumerated().count { index, pixel in
            let column = index % bitmap.width
            return column >= Int(CGFloat(columns.lowerBound) * cellWidth)
                && column < Int(CGFloat(columns.upperBound) * cellWidth)
                && isInk(pixel)
        }
    }

    private func hasNonMonochromeInk(in bitmap: Bitmap, columns: Range<Int>) -> Bool {
        pixels(in: bitmap).enumerated().contains { index, pixel in
            let column = index % bitmap.width
            return column >= Int(CGFloat(columns.lowerBound) * cellWidth)
                && column < Int(CGFloat(columns.upperBound) * cellWidth)
                && isInk(pixel)
                && max(pixel.red, pixel.green, pixel.blue) - min(pixel.red, pixel.green, pixel.blue) > 30
        }
    }

    private func isInk(_ pixel: Pixel) -> Bool {
        pixel.red != background.red || pixel.green != background.green || pixel.blue != background.blue
    }

    private func pixels(in bitmap: Bitmap) -> [Pixel] {
        let image = bitmap.context.makeImage()!
        let data = image.dataProvider!.data!
        let bytes = CFDataGetBytePtr(data)!
        return (0..<(bitmap.width * bitmap.height)).map { index in
            let offset = index * 4
            return Pixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2])
        }
    }
}

private struct Bitmap {
    let context: CGContext
    let width: Int
    let height: Int
}

private struct Pixel {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}
