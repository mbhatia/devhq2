import AppKit
import CodeEditTextView
import Foundation
import SwiftUI

@main
struct DevHQApp: App {
    @StateObject private var workspace = WorkspaceModel()
    @StateObject private var plugins: LuaPluginHost
    private static var snapshotWindow: NSWindow?

    init() {
        let plugins = LuaPluginHost()
        plugins.loadUserConfiguration()
        _plugins = StateObject(wrappedValue: plugins)

        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.async {
                Self.prepareSnapshotWindow(settings: plugins.settings)
                if let line = Self.argumentValue(after: "--fold-line").flatMap(Int.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        Self.foldLine(line)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    Self.captureWindow(at: path)
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup("DevHQ") {
            ContentView(workspace: workspace, settings: plugins.settings)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    workspace.chooseFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    workspace.saveSelected()
                }
                .keyboardShortcut("s")
                .disabled(workspace.selectedDocument == nil)
            }
        }
    }

    private static func prepareSnapshotWindow(settings: EditorSettings) {
        let model = WorkspaceModel()
        let content = ContentView(workspace: model, settings: settings)
            .frame(width: 1200, height: 760)
        let hostingView = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DevHQ"
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        snapshotWindow = window
    }

    private static func foldLine(_ line: Int) {
        guard line > 0,
              let window = snapshotWindow,
              let contentView = window.contentView,
              let ribbon = findSubview(named: "LineFoldRibbonView", in: contentView),
              let textView = findSubview(ofType: TextView.self, in: contentView),
              let linePosition = textView.layoutManager.textLineForIndex(line - 1) else { return }

        let point = ribbon.convert(
            NSPoint(x: ribbon.bounds.midX, y: linePosition.yPos + (linePosition.height / 2)),
            to: nil
        )
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }
        ribbon.mouseDown(with: event)
        contentView.layoutSubtreeIfNeeded()
    }

    private static func findSubview(named name: String, in view: NSView) -> NSView? {
        if String(describing: type(of: view)).hasSuffix(name) {
            return view
        }
        return view.subviews.lazy.compactMap { findSubview(named: name, in: $0) }.first
    }

    private static func findSubview<T: NSView>(ofType type: T.Type, in view: NSView) -> T? {
        if let view = view as? T {
            return view
        }
        return view.subviews.lazy.compactMap { findSubview(ofType: type, in: $0) }.first
    }

    private static func argumentValue(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func captureWindow(at path: String) {
        guard let window = snapshotWindow,
              let view = window.contentView else { return }
        window.setContentSize(NSSize(width: 1200, height: 760))
        view.layoutSubtreeIfNeeded()
        let width = max(Int(view.bounds.width * 2), 2)
        let height = max(Int(view.bounds.height * 2), 2)
        guard let image = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        image.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
