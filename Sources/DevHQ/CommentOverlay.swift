import SwiftUI

/// Floating panel for one comment thread, anchored near the thread in the
/// editor. Return saves, Esc cancels, and Ctrl-R/⌘R resolves — those keys are
/// handled by `CommentEditorCoordinator`'s event monitor while the overlay is
/// open; the buttons mirror them for the mouse.
struct CommentOverlayView: View {
    let thread: CommentThread
    let initialInput: String
    let onInputChange: (String) -> Void
    let onSave: (String) -> Void
    let onResolve: () -> Void
    let onCancel: (String) -> Void

    @State private var input: String
    @FocusState private var isInputFocused: Bool

    init(
        thread: CommentThread,
        initialInput: String,
        onInputChange: @escaping (String) -> Void,
        onSave: @escaping (String) -> Void,
        onResolve: @escaping () -> Void,
        onCancel: @escaping (String) -> Void
    ) {
        self.thread = thread
        self.initialInput = initialInput
        self.onInputChange = onInputChange
        self.onSave = onSave
        self.onResolve = onResolve
        self.onCancel = onCancel
        _input = State(initialValue: initialInput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(header)
                .font(.devHQ(.caption1, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(thread.messages.enumerated()), id: \.offset) { _, message in
                        Text(line(for: message))
                            .font(.devHQ(size: 12))
                            .foregroundStyle(
                                message.state == .resolved ? Color.secondary : Color.primary
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                TextField("Comment", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.devHQ(size: 12))
                    .focused($isInputFocused)
                    .accessibilityIdentifier("comment-overlay-input")
                    .onChange(of: input) { newValue in
                        onInputChange(newValue)
                    }

                HStack(spacing: 8) {
                    Button(thread.state == .draft ? "Save" : "Reply") {
                        onSave(input)
                    }
                    if thread.state == .open {
                        Button("Resolve", action: onResolve)
                    }
                    Button("Cancel") {
                        onCancel(input)
                    }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(thread.state == .resolved ? Color.gray : Color.orange)
                .frame(height: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.45)))
        .shadow(radius: 8, y: 3)
        .accessibilityIdentifier("comment-overlay")
        .onAppear {
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
    }

    private var header: String {
        "\(thread.state.rawValue)  \(thread.file):\(thread.range.start.line):\(thread.range.start.col)"
    }

    private func line(for message: CommentMessage) -> String {
        let state = message.state.flatMap { $0 == .open ? nil : " [\($0.rawValue)]" } ?? ""
        return "\(message.author.label)\(state): \(message.body)"
    }
}
