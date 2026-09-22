import AppKit
import Foundation
import SwiftUI

/// Routes configured command shortcuts before AppKit delivers them to the
/// focused view (including a terminal's PTY input view).
@MainActor
final class KeyBindingRouter {
    private let bindings: KeyBindingRegistry
    private let commandManager: CommandManager
    private let context: () -> CommandContext
    private let reportError: (Error) -> Void

    init(
        bindings: KeyBindingRegistry? = nil,
        commandManager: CommandManager,
        context: @escaping () -> CommandContext,
        reportError: @escaping (Error) -> Void = { _ in }
    ) {
        self.bindings = bindings ?? .shared
        self.commandManager = commandManager
        self.context = context
        self.reportError = reportError
    }

    /// Returns true only when a configured command was available and routed.
    func route(_ event: NSEvent) -> Bool {
        guard let commandID = bindings.command(for: event) else { return false }
        let commandContext = context()
        let listing = commandManager.commandListing(in: commandContext)
        guard listing.commands.contains(where: { $0.id == commandID }) else { return false }

        do {
            try commandManager.execute(id: commandID, in: commandContext)
            return true
        } catch let error as CommandManagerError {
            switch error {
            case .commandOutOfScope, .commandUnavailable:
                return false
            case .invalidIdentifier, .commandNotFound:
                reportError(error)
                return true
            }
        } catch {
            reportError(error)
            return true
        }
    }
}

/// Owns an AppKit-local monitor for the SwiftUI content view's window.
struct KeyBindingRoutingMonitor: NSViewRepresentable {
    let router: KeyBindingRouter
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(router: router, isEnabled: isEnabled)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.router = router
        context.coordinator.isEnabled = isEnabled
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var router: KeyBindingRouter
        var isEnabled: Bool
        private weak var view: NSView?
        private var monitor: Any?

        init(router: KeyBindingRouter, isEnabled: Bool) {
            self.router = router
            self.isEnabled = isEnabled
        }

        func install(for view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let view = self.view else { return event }
                return self.shouldRoute(event, in: view.window) ? nil : event
            }
        }

        /// Kept separate from the AppKit monitor closure for routing tests.
        func shouldRoute(_ event: NSEvent, in window: NSWindow?) -> Bool {
            isEnabled && event.window === window && router.route(event)
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
