import SwiftUI

/// Right-hand review pane: one entry per comment thread in the active
/// worktree, sorted by file then start line. Clicking an entry opens the
/// thread's file (or a read-only snapshot for stale commits) and moves the
/// caret to the range start.
struct ReviewSidebarPane: View {
    @ObservedObject var controller: CommentThreadsController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                Text("Review")
                    .font(.devHQ(.headline, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    controller.isSidebarVisible = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Hide Review Sidebar")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            if controller.sortedThreads.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No Comments").font(.devHQ(.title3, weight: .semibold))
                    Text("Select text and run devhq: add comment to start a review thread.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(controller.sortedThreads) { thread in
                            ReviewSidebarRow(thread: thread) {
                                controller.openThread(thread)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            controller.ensureLoaded()
        }
    }
}

private struct ReviewSidebarRow: View {
    let thread: CommentThread
    let open: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(thread.state == .resolved ? Color.gray : Color.orange)
                    .frame(width: 7, height: 7)
                Text(header)
                    .font(.devHQ(.callout, weight: .semibold))
                    .lineLimit(1)
            }
            if !preview.isEmpty {
                Text(preview)
                    .font(.devHQ(.caption1))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 13)
            }
        }
        .opacity(thread.state == .resolved ? 0.55 : 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
        .help(tooltip)
        .accessibilityIdentifier("review-sidebar-entry")
    }

    private var header: String {
        let basename = (thread.file as NSString).lastPathComponent
        let extra = thread.messages.count > 1 ? " (\(thread.messages.count))" : ""
        return "\(basename):\(thread.range.start.line)\(extra)"
    }

    private var preview: String {
        thread.firstMessage.body
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var tooltip: String {
        let last = thread.messages.last
        return "\(thread.file):\(thread.range.start.line) [\(thread.state.rawValue)]"
            + " last from \(last?.author.label ?? "you")"
    }
}
