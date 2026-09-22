import AppKit
import Foundation
import XCTest
@testable import DevHQ

/// Opt-in redraw measurements for the Core Text terminal renderer. These draw
/// into a bitmap CGContext, rather than timing a layout-only code path or a
/// window-server refresh.
final class TerminalRendererBenchmarkTests: XCTestCase {
    private let columns = 120
    private let rows = 40
    private let cellWidth: CGFloat = 8
    private let cellHeight: CGFloat = 18
    private let baseline: CGFloat = 14

    @MainActor
    func testOffscreenRedrawWorkloads() throws {
        guard ProcessInfo.processInfo.environment["DEVHQ_RUN_TERMINAL_RENDERER_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set DEVHQ_RUN_TERMINAL_RENDERER_BENCHMARKS=1 to run redraw measurements")
        }

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: columns * Int(cellWidth),
            pixelsHigh: rows * Int(cellHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let bitmapGraphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        // Match NativeTerminalView's flipped AppKit coordinate space.
        let graphics = NSGraphicsContext(cgContext: bitmapGraphics.cgContext, flipped: true)
        let fonts = TerminalTextRenderer.Fonts(
            regular: TerminalFont.regular(named: "", size: 13),
            bold: TerminalFont.bold(named: "", size: 13),
            italic: TerminalFont.italic(named: "", size: 13),
            boldItalic: TerminalFont.boldItalic(named: "", size: 13)
        )
        let unchanged = terminalRows(frame: 0, workload: .unchanged)
        let multilingual = (0..<16).map { terminalRows(frame: $0, workload: .multilingual) }
        let doom = (0..<16).map { terminalRows(frame: $0, workload: .doom) }

        let cachedRenderer = TerminalTextRenderer()
        draw(rows: unchanged, renderer: cachedRenderer, graphics: graphics, fonts: fonts)
        let hitsBefore = cachedRenderer.cacheStatistics.hits
        let cached = measure(repetitions: 16) {
            self.draw(rows: unchanged, renderer: cachedRenderer, graphics: graphics, fonts: fonts)
        }
        XCTAssertGreaterThan(cachedRenderer.cacheStatistics.hits, hitsBefore)

        let multilingualRenderer = TerminalTextRenderer()
        let multilingualChanged = measure(repetitions: multilingual.count) { index in
            self.draw(rows: multilingual[index], renderer: multilingualRenderer, graphics: graphics, fonts: fonts)
        }
        XCTAssertGreaterThan(multilingualRenderer.cacheStatistics.misses, 0)

        let doomRenderer = TerminalTextRenderer()
        let doomChurn = measure(repetitions: doom.count) { index in
            self.draw(rows: doom[index], renderer: doomRenderer, graphics: graphics, fonts: fonts)
        }
        XCTAssertGreaterThan(doomRenderer.cacheStatistics.misses, 0)

        // This is the previous per-cell AppKit drawing shape. It is retained
        // solely as an apples-to-apples workload comparator, not an end-to-end
        // reconstruction of the historical application.
        let legacyCached = measure(repetitions: 16) { _ in
            self.drawLegacy(rows: unchanged, graphics: graphics, fonts: fonts)
        }
        let legacyMultilingual = measure(repetitions: multilingual.count) { index in
            self.drawLegacy(rows: multilingual[index], graphics: graphics, fonts: fonts)
        }
        let legacyDoom = measure(repetitions: doom.count) { index in
            self.drawLegacy(rows: doom[index], graphics: graphics, fonts: fonts)
        }

        XCTAssertNotNil(bitmap.bitmapData)
        print("terminal-renderer-benchmark geometry=\(columns)x\(rows) "
            + "cache_hit_median_ms=\(formatMilliseconds(cached)) "
            + "multilingual_changed_median_ms=\(formatMilliseconds(multilingualChanged)) "
            + "doom_churn_median_ms=\(formatMilliseconds(doomChurn)) "
            + "legacy_cache_hit_median_ms=\(formatMilliseconds(legacyCached)) "
            + "legacy_multilingual_changed_median_ms=\(formatMilliseconds(legacyMultilingual)) "
            + "legacy_doom_churn_median_ms=\(formatMilliseconds(legacyDoom)) "
            + "cache_hits=\(cachedRenderer.cacheStatistics.hits) "
            + "multilingual_misses=\(multilingualRenderer.cacheStatistics.misses) "
            + "doom_misses=\(doomRenderer.cacheStatistics.misses)")
    }

    @MainActor
    private func draw(
        rows: [[TerminalCell]],
        renderer: TerminalTextRenderer,
        graphics: NSGraphicsContext,
        fonts: TerminalTextRenderer.Fonts
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = graphics.cgContext
        context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
        context.fill(CGRect(
            x: 0,
            y: 0,
            width: CGFloat(columns) * cellWidth,
            height: CGFloat(rows.count) * cellHeight
        ))
        for (row, cells) in rows.enumerated() {
            let origin = CGPoint(x: 0, y: CGFloat(row) * cellHeight)
            renderer.draw(
                row: cells,
                fonts: fonts,
                cellWidth: cellWidth,
                baseline: baseline,
                rowOrigin: origin,
                context: context,
                foreground: foreground
            )
            renderer.drawDecorations(
                row: cells,
                cellWidth: cellWidth,
                baseline: baseline,
                rowOrigin: origin,
                context: context,
                foreground: foreground
            )
        }
    }

    @MainActor
    private func drawLegacy(
        rows: [[TerminalCell]],
        graphics: NSGraphicsContext,
        fonts: TerminalTextRenderer.Fonts
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = graphics.cgContext
        context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
        context.fill(CGRect(
            x: 0,
            y: 0,
            width: CGFloat(columns) * cellWidth,
            height: CGFloat(rows.count) * cellHeight
        ))
        for (row, cells) in rows.enumerated() {
            let y = CGFloat(row) * cellHeight
            for (column, cell) in cells.enumerated() where !cell.text.isEmpty && cell.text != " " {
                let primary = fonts.font(for: cell)
                let font = primary
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: foreground(column: column, cell: cell)
                ]
                if cell.underline || cell.hyperlink != nil {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if cell.strikethrough {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                let string = NSAttributedString(string: cell.text, attributes: attributes)
                string.draw(at: CGPoint(
                    x: CGFloat(column) * cellWidth,
                    y: y + baseline - font.ascender
                ))
            }
        }
    }

    private func measure(repetitions: Int, body: () -> Void) -> [Double] {
        (0..<repetitions).map { _ in
            let started = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }
    }

    private func measure(repetitions: Int, body: (Int) -> Void) -> [Double] {
        (0..<repetitions).map { index in
            let started = DispatchTime.now().uptimeNanoseconds
            body(index)
            return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }
    }

    private func formatMilliseconds(_ samples: [Double]) -> String {
        let median = samples.sorted()[samples.count / 2]
        let values = samples.map { String(format: "%.3f", $0) }.joined(separator: ",")
        return String(format: "%.3f", median) + " samples_ms=[\(values)]"
    }

    private func foreground(column: Int, cell: TerminalCell) -> NSColor {
        cell.inverse ? (cell.background?.nsColor ?? .textBackgroundColor) : (cell.foreground?.nsColor ?? .textColor)
    }

    private enum Workload { case unchanged, multilingual, doom }

    private func terminalRows(frame: Int, workload: Workload) -> [[TerminalCell]] {
        (0..<rows).map { row in
            (0..<columns).map { column in
                switch workload {
                case .unchanged:
                    return cell(text: column.isMultiple(of: 17) ? "●" : "a", column: column, row: row, frame: 0)
                case .multilingual:
                    let texts = ["c", "é", "ع", "न", "漢", "한", "👩🏽‍💻", "é", "🧪"]
                    let index = (column + row + frame) % texts.count
                    return cell(text: texts[index], column: column, row: row, frame: frame)
                case .doom:
                    let scalar = UnicodeScalar(33 + ((column * 13 + row * 7 + frame * 19) % 80))!
                    return cell(text: String(scalar), column: column, row: row, frame: frame)
                }
            }
        }
    }

    private func cell(text: String, column: Int, row: Int, frame: Int) -> TerminalCell {
        TerminalCell(
            text: text,
            foreground: TerminalRGB(red: UInt8((column * 17 + frame * 11) % 255), green: UInt8((row * 23 + frame * 7) % 255), blue: 180),
            background: (column + row + frame).isMultiple(of: 11) ? TerminalRGB(red: 24, green: 28, blue: 36) : nil,
            bold: (column + frame).isMultiple(of: 9),
            italic: (row + frame).isMultiple(of: 7),
            underline: (column + row + frame).isMultiple(of: 29),
            strikethrough: (column * 3 + row + frame).isMultiple(of: 31),
            inverse: false,
            width: 1,
            hyperlink: (column + row + frame).isMultiple(of: 37) ? "https://example.invalid" : nil
        )
    }
}
