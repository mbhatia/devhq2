import AppKit
import Foundation
import SwiftUI

@main
struct DevHQApp: App {
    @StateObject private var workspace = WorkspaceModel()
    private static var snapshotWindow: NSWindow?

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.async {
                Self.prepareSnapshotWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    Self.captureWindow(at: path)
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup("DevHQ") {
            ContentView(workspace: workspace)
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

    private static func prepareSnapshotWindow() {
        let model = WorkspaceModel()
        let content = ContentView(workspace: model)
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
