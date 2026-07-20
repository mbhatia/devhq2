import AppKit
import SwiftUI

struct WorkspaceDividerPositions: Equatable {
    let first: CGFloat
    let second: CGFloat

    static func make(
        origin: CGFloat,
        worktreeExplorerWidth: CGFloat,
        fileExplorerWidth: CGFloat,
        dividerThickness: CGFloat
    ) -> Self {
        let first = origin + worktreeExplorerWidth
        return Self(
            first: first,
            second: first + dividerThickness + fileExplorerWidth
        )
    }
}

/// Restores explicit divider positions after SwiftUI has attached and laid out
/// its `HSplitView`. `idealWidth` only participates in the initial sizing pass;
/// it does not reliably move dividers to persisted positions.
struct WorkspaceSplitViewRestorer: NSViewRepresentable {
    let worktreeExplorerWidth: Double
    let fileExplorerWidth: Double
    let requestID: Int
    let onRestored: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WorkspaceSplitViewProbe {
        let view = WorkspaceSplitViewProbe()
        view.coordinator = context.coordinator
        context.coordinator.configure(
            worktreeExplorerWidth: worktreeExplorerWidth,
            fileExplorerWidth: fileExplorerWidth,
            requestID: requestID,
            onRestored: onRestored
        )
        return view
    }

    func updateNSView(_ nsView: WorkspaceSplitViewProbe, context: Context) {
        context.coordinator.configure(
            worktreeExplorerWidth: worktreeExplorerWidth,
            fileExplorerWidth: fileExplorerWidth,
            requestID: requestID,
            onRestored: onRestored
        )
        context.coordinator.scheduleRestoration(from: nsView)
    }

    static func restoreWidths(
        in splitView: NSSplitView,
        worktreeExplorerWidth: CGFloat,
        fileExplorerWidth: CGFloat
    ) -> Bool {
        guard splitView.isVertical, splitView.arrangedSubviews.count >= 3 else {
            return false
        }

        splitView.layoutSubtreeIfNeeded()
        let positions = WorkspaceDividerPositions.make(
            origin: splitView.bounds.minX,
            worktreeExplorerWidth: worktreeExplorerWidth,
            fileExplorerWidth: fileExplorerWidth,
            dividerThickness: splitView.dividerThickness
        )
        splitView.setPosition(positions.first, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()

        // Use the first pane's actual constrained edge. This preserves the file
        // pane width if AppKit had to clamp the first requested position.
        let firstPaneEdge = splitView.arrangedSubviews[0].frame.maxX
        splitView.setPosition(
            firstPaneEdge + splitView.dividerThickness + fileExplorerWidth,
            ofDividerAt: 1
        )
        splitView.layoutSubtreeIfNeeded()
        return true
    }

    @MainActor
    final class Coordinator {
        private var worktreeExplorerWidth = 0.0
        private var fileExplorerWidth = 0.0
        private var requestID: Int?
        private var onRestored: (() -> Void)?
        private var isScheduled = false
        private var hasRestored = false
        private var attemptCount = 0

        func configure(
            worktreeExplorerWidth: Double,
            fileExplorerWidth: Double,
            requestID: Int,
            onRestored: @escaping () -> Void
        ) {
            self.worktreeExplorerWidth = worktreeExplorerWidth
            self.fileExplorerWidth = fileExplorerWidth
            self.onRestored = onRestored
            guard self.requestID != requestID else { return }
            self.requestID = requestID
            hasRestored = false
            attemptCount = 0
        }

        func scheduleRestoration(from probe: WorkspaceSplitViewProbe) {
            guard !hasRestored, !isScheduled else { return }
            isScheduled = true
            DispatchQueue.main.async { [weak self, weak probe] in
                guard let self, let probe else { return }
                self.isScheduled = false
                self.restore(from: probe)
            }
        }

        private func restore(from probe: WorkspaceSplitViewProbe) {
            guard !hasRestored else { return }
            guard probe.window != nil,
                  let splitView = Self.containingWorkspaceSplitView(of: probe),
                  WorkspaceSplitViewRestorer.restoreWidths(
                    in: splitView,
                    worktreeExplorerWidth: worktreeExplorerWidth,
                    fileExplorerWidth: fileExplorerWidth
                  ) else {
                retry(from: probe)
                return
            }

            hasRestored = true
            onRestored?()
        }

        private func retry(from probe: WorkspaceSplitViewProbe) {
            attemptCount += 1
            guard attemptCount < 30, probe.superview != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self, weak probe] in
                guard let self, let probe else { return }
                self.scheduleRestoration(from: probe)
            }
        }

        private static func containingWorkspaceSplitView(
            of probe: NSView
        ) -> NSSplitView? {
            var ancestor = probe.superview
            while let view = ancestor {
                if let splitView = view as? NSSplitView,
                   splitView.isVertical,
                   splitView.arrangedSubviews.count >= 3 {
                    return splitView
                }
                ancestor = view.superview
            }
            return nil
        }
    }
}

@MainActor
final class WorkspaceSplitViewProbe: NSView {
    weak var coordinator: WorkspaceSplitViewRestorer.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.scheduleRestoration(from: self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        coordinator?.scheduleRestoration(from: self)
    }
}
