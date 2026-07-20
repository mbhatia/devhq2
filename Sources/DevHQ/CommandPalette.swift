import AppKit
import SwiftUI

@MainActor
final class CommandPaletteController: ObservableObject {
    @Published private(set) var isPresented = false
    @Published var query = "" {
        didSet {
            keepSelectionInFilteredCommands()
        }
    }
    @Published private(set) var selectedCommandID: String?
    @Published private(set) var errorMessage: String?

    private(set) var presentedContext: CommandContext?
    private(set) var commands: [RegisteredCommand] = []
    private let commandManager: CommandManager

    init(commandManager: CommandManager) {
        self.commandManager = commandManager
    }

    var filteredCommands: [RegisteredCommand] {
        guard !query.isEmpty else { return commands }
        return commands.filter {
            $0.title.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    func present(in context: CommandContext) {
        presentedContext = context
        query = ""
        errorMessage = nil
        isPresented = true

        let listing = commandManager.commandListing(in: context)
        commands = listing.commands
        selectedCommandID = commands.first?.id
        errorMessage = predicateErrorMessage(for: listing.predicateFailures)
    }

    func dismiss() {
        isPresented = false
        query = ""
        commands = []
        selectedCommandID = nil
        presentedContext = nil
        errorMessage = nil
    }

    func moveSelectionUp() {
        moveSelection(by: -1)
    }

    func moveSelectionDown() {
        moveSelection(by: 1)
    }

    func executeSelected() {
        guard let selectedCommandID,
              filteredCommands.contains(where: { $0.id == selectedCommandID }) else { return }
        execute(commandID: selectedCommandID)
    }

    func execute(_ command: RegisteredCommand) {
        guard commands.contains(where: { $0.id == command.id }) else { return }
        execute(commandID: command.id)
    }

    private func execute(commandID: String) {
        guard let presentedContext else { return }
        do {
            try commandManager.execute(id: commandID, in: presentedContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func predicateErrorMessage(
        for failures: [CommandPredicateFailure]
    ) -> String? {
        guard let first = failures.first else { return nil }
        let remainingCount = failures.count - 1
        let remainingSuffix = remainingCount == 0 ? "" : " (+\(remainingCount) more)"
        return "Could not evaluate \(first.commandID): \(first.error.localizedDescription)"
            + remainingSuffix
    }

    private func keepSelectionInFilteredCommands() {
        let filteredCommands = filteredCommands
        guard !filteredCommands.isEmpty else {
            selectedCommandID = nil
            return
        }
        guard let selectedCommandID,
              filteredCommands.contains(where: { $0.id == selectedCommandID }) else {
            self.selectedCommandID = filteredCommands.first?.id
            return
        }
    }

    private func moveSelection(by offset: Int) {
        let filteredCommands = filteredCommands
        guard !filteredCommands.isEmpty else {
            selectedCommandID = nil
            return
        }

        guard let selectedCommandID,
              let currentIndex = filteredCommands.firstIndex(where: {
                  $0.id == selectedCommandID
              }) else {
            self.selectedCommandID = offset < 0
                ? filteredCommands.last?.id
                : filteredCommands.first?.id
            return
        }

        let nextIndex = (currentIndex + offset + filteredCommands.count)
            % filteredCommands.count
        self.selectedCommandID = filteredCommands[nextIndex].id
    }
}

struct CommandPalette: View {
    @ObservedObject var controller: CommandPaletteController

    var body: some View {
        if controller.isPresented {
            ZStack {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        controller.dismiss()
                    }

                CommandPaletteCard(controller: controller)
                    .frame(width: 560)
                    .frame(maxHeight: 440)
                    .padding(24)
            }
        }
    }
}

private struct CommandPaletteCard: View {
    @ObservedObject var controller: CommandPaletteController
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                TextField("Type a command", text: $controller.query)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                    .accessibilityIdentifier("command-palette-search")
            }
            .font(.system(size: 16))
            .padding(.horizontal, 14)
            .frame(height: 48)

            Divider()

            if controller.filteredCommands.isEmpty {
                Text(controller.errorMessage ?? "No commands found")
                    .foregroundColor(
                        Color(
                            nsColor: controller.errorMessage == nil
                                ? .secondaryLabelColor
                                : .systemRed
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(controller.filteredCommands) { command in
                                Button {
                                    controller.execute(command)
                                } label: {
                                    HStack {
                                        Text(command.title)
                                            .lineLimit(1)
                                        Spacer(minLength: 12)
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: 34)
                                    .contentShape(Rectangle())
                                    .background(
                                        command.id == controller.selectedCommandID
                                            ? Color.accentColor.opacity(0.22)
                                            : Color.clear
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                                .id(command.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 330)
                    .onChange(of: controller.selectedCommandID) { selectedCommandID in
                        guard let selectedCommandID else { return }
                        withAnimation(.easeOut(duration: 0.08)) {
                            proxy.scrollTo(selectedCommandID, anchor: .center)
                        }
                    }
                }

                if let errorMessage = controller.errorMessage {
                    Divider()
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        .background {
            CommandPaletteKeyboardMonitor { key in
                switch key {
                case .up: controller.moveSelectionUp()
                case .down: controller.moveSelectionDown()
                case .return: controller.executeSelected()
                case .escape: controller.dismiss()
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                searchIsFocused = true
            }
        }
    }
}

private struct CommandPaletteKeyboardMonitor: NSViewRepresentable {
    enum Key {
        case up
        case down
        case `return`
        case escape
    }

    let onKey: (Key) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onKey: onKey)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKey = onKey
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var onKey: (Key) -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(onKey: @escaping (Key) -> Void) {
            self.onKey = onKey
        }

        deinit {
            uninstall()
        }

        func install(for view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard let self,
                      let view = self.view,
                      event.window === view.window,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let key = Self.key(for: event.keyCode) else { return event }
                self.onKey(key)
                return nil
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private static func key(for keyCode: UInt16) -> Key? {
            switch keyCode {
            case 126: .up
            case 125: .down
            case 36, 76: .return
            case 53: .escape
            default: nil
            }
        }
    }
}
