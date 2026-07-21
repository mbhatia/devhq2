import AppKit
import CodeEditSourceEditor
import SwiftUI

@MainActor
final class DiffEditorPresentation: ObservableObject {
    @Published private(set) var statusMessage: String?
    @Published private(set) var snapshot = DiffEditorSnapshot()

    private(set) lazy var coordinator = DiffEditorCoordinator()
    private var generation = 0
    private var activeContext: DiffEditorContext?
    private var isEnabled = false

    func load(_ configuration: DiffEditorConfiguration?) async {
        generation += 1
        let requestedGeneration = generation
        activeContext = configuration?.context
        isEnabled = configuration?.isEnabled == true

        guard let configuration, configuration.isEnabled else {
            statusMessage = nil
            snapshot = .init()
            coordinator.update(snapshot: snapshot, isEnabled: false)
            return
        }

        // Never display markers or a hunk from the prior context while the new
        // asynchronous request is in flight.
        statusMessage = nil
        snapshot = .init()
        coordinator.update(snapshot: snapshot, isEnabled: true)

        do {
            let snapshot = try await configuration.load(configuration.context)
            guard !Task.isCancelled,
                  requestedGeneration == generation,
                  activeContext == configuration.context,
                  isEnabled else {
                return
            }
            statusMessage = snapshot.statusMessage
            self.snapshot = snapshot
            coordinator.update(snapshot: snapshot, isEnabled: true)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  requestedGeneration == generation,
                  activeContext == configuration.context,
                  isEnabled else {
                return
            }
            statusMessage = error.localizedDescription
            snapshot = .init()
            coordinator.update(snapshot: snapshot, isEnabled: true)
        }
    }

    func invalidate() {
        generation += 1
        activeContext = nil
        isEnabled = false
        statusMessage = nil
        snapshot = .init()
        coordinator.update(snapshot: snapshot, isEnabled: false)
    }
}

@MainActor
final class DiffEditorCoordinator: NSObject, @preconcurrency TextViewCoordinator {
    private weak var controller: TextViewController?
    private weak var markerView: DiffGutterMarkerView?
    private(set) weak var overlayView: NSView?
    private var clickMonitor: Any?
    private var snapshot = DiffEditorSnapshot()
    private var isEnabled = false

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
    }

    func controllerDidAppear(controller: TextViewController) {
        installMarkerView(in: controller)
        installClickMonitor()
        refreshMarkerView()
    }

    func textViewDidChangeText(controller: TextViewController) {
        refreshMarkerView()
    }

    func destroy() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
        markerView?.removeFromSuperview()
        overlayView?.removeFromSuperview()
        markerView = nil
        overlayView = nil
        controller = nil
    }

    func update(snapshot: DiffEditorSnapshot, isEnabled: Bool) {
        self.snapshot = snapshot
        self.isEnabled = isEnabled
        if !isEnabled {
            closeOverlay()
        } else if let overlay = overlayView,
                  overlay.superview != nil,
                  !snapshot.hunks.contains(where: { hunk in
                      overlay.identifier?.rawValue == hunk.id
                  }) {
            closeOverlay()
        }
        refreshMarkerView()
    }

    private func installMarkerView(in controller: TextViewController) {
        guard markerView == nil,
              let gutter = firstSubview(of: GutterView.self, in: controller.scrollView) else {
            return
        }

        let markerView = DiffGutterMarkerView(frame: gutter.bounds)
        markerView.autoresizingMask = [.width, .height]
        markerView.onSelectHunk = { [weak self] hunkID in
            self?.openOverlay(for: hunkID)
        }
        gutter.addSubview(markerView, positioned: .above, relativeTo: nil)
        self.markerView = markerView
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    private func refreshMarkerView() {
        markerView?.isHidden = !isEnabled
        markerView?.markers = isEnabled ? snapshot.markers : []
        markerView?.textViewController = controller
        markerView?.needsDisplay = true
    }

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            self?.handleOverlayEvent(event) ?? event
        }
    }

    func handleOverlayEvent(_ event: NSEvent) -> NSEvent? {
        guard let overlay = overlayView else { return event }

        switch event.type {
        case .leftMouseDown:
            guard event.window === overlay.window else {
                closeOverlay()
                return event
            }
            let point = overlay.convert(event.locationInWindow, from: nil)
            if !overlay.bounds.contains(point) {
                closeOverlay()
            }
            return event
        case .keyDown where event.window === overlay.window
            && (event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}"):
            closeOverlay()
            return nil
        default:
            return event
        }
    }

    private func openOverlay(for hunkID: String) {
        guard isEnabled,
              let controller,
              let hunk = snapshot.hunks.first(where: { $0.id == hunkID }) else {
            return
        }

        closeOverlay()
        presentOverlay(hunk, in: controller.view)
    }

    func presentOverlay(_ hunk: DiffEditorHunk, in container: NSView) {
        let overlay = NSHostingView(rootView: DiffHunkOverlay(hunk: hunk))
        overlay.identifier = NSUserInterfaceItemIdentifier(hunk.id)
        overlay.translatesAutoresizingMaskIntoConstraints = true

        let desiredHeight = min(420, max(110, CGFloat(hunk.metadata.count + hunk.lines.count + 1) * 19 + 42))
        let width = min(760, max(1, container.bounds.width - 32))
        let height = min(desiredHeight, max(1, container.bounds.height - 36))
        let y = container.isFlipped
            ? container.bounds.minY + 18
            : container.bounds.maxY - height - 18
        overlay.frame = NSRect(
            x: container.bounds.midX - width / 2,
            y: y,
            width: width,
            height: height
        )
        overlay.autoresizingMask = [.minXMargin, .maxXMargin, container.isFlipped ? .maxYMargin : .minYMargin]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlayView = overlay
    }

    func closeOverlay() {
        overlayView?.removeFromSuperview()
        overlayView = nil
    }
}

@MainActor
private final class DiffGutterMarkerView: NSView {
    weak var textViewController: TextViewController?
    var markers: [DiffEditorMarker] = []
    var onSelectHunk: ((String) -> Void)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        marker(at: point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        guard let marker = marker(at: convert(event.locationInWindow, from: nil)) else { return }
        onSelectHunk?(marker.hunkID)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let controller = textViewController else { return }

        for marker in markers {
            guard let rect = markerRect(for: marker, controller: controller), rect.intersects(dirtyRect) else {
                continue
            }
            marker.kind.color.setFill()
            switch marker.kind {
            case .deleted:
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 1, y: rect.midY - 4))
                path.line(to: NSPoint(x: 7, y: rect.midY))
                path.line(to: NSPoint(x: 1, y: rect.midY + 4))
                path.close()
                path.fill()
            case .added, .modified:
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    private func marker(at point: NSPoint) -> DiffEditorMarker? {
        guard point.x <= 10, let controller = textViewController else { return nil }
        return markers.last { marker in
            markerRect(for: marker, controller: controller)?.insetBy(dx: -2, dy: -2).contains(point) == true
        }
    }

    private func markerRect(for marker: DiffEditorMarker, controller: TextViewController) -> NSRect? {
        guard marker.line > 0,
              let line = controller.textView.layoutManager.textLineForIndex(marker.line - 1) else {
            return nil
        }
        let height = marker.kind == .deleted ? max(8, min(12, line.height)) : max(3, line.height)
        return NSRect(x: 1, y: line.yPos + (line.height - height) / 2, width: 5, height: height)
    }
}

private extension DiffEditorMarker.Kind {
    var color: NSColor {
        switch self {
        case .added: .systemGreen
        case .modified: .systemBlue
        case .deleted: .systemRed
        }
    }
}

private struct DiffHunkOverlay: View {
    let hunk: DiffEditorHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(hunk.metadata.enumerated()), id: \.offset) { _, line in
                        hunkLine(line, kind: .metadata)
                    }
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        hunkLine(line.text, kind: line.kind)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.45)))
        .shadow(radius: 8, y: 3)
        .accessibilityIdentifier("diff-hunk-overlay")
    }

    private func hunkLine(_ text: String, kind: DiffEditorHunk.Line.Kind) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(kind.foregroundColor)
            .padding(.horizontal, 8)
            .frame(minHeight: 19)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kind.backgroundColor)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private extension DiffEditorHunk.Line.Kind {
    var foregroundColor: Color {
        switch self {
        case .metadata, .header: .secondary
        case .context: .primary
        case .addition: Color(nsColor: .systemGreen)
        case .deletion: Color(nsColor: .systemRed)
        }
    }

    var backgroundColor: Color {
        switch self {
        case .metadata: Color(nsColor: .systemGray).opacity(0.12)
        case .header: Color(nsColor: .systemBlue).opacity(0.12)
        case .context: .clear
        case .addition: Color(nsColor: .systemGreen).opacity(0.12)
        case .deletion: Color(nsColor: .systemRed).opacity(0.12)
        }
    }
}
