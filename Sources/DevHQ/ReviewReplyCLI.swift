import Foundation

/// Headless `devhq review reply <comment-id> --message <text>` mode. It runs
/// before the app UI starts, appends an agent reply to a comment thread found
/// in the workspace state directory, and exits.
enum ReviewReplyCLI {
    static let usage = """
    Usage:
      devhq review reply <comment-id> --message <text>

    Environment:
      DEVHQ_CONFIG_DIR  DevHQ configuration directory containing ws/
      AGENT_ID          Optional agent identity stored with the reply
    """

    static func isReviewInvocation(_ arguments: [String]) -> Bool {
        arguments.count > 1 && arguments[1] == "review"
    }

    @discardableResult
    static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        output: (String) -> Void = { print($0) },
        errorOutput: (String) -> Void = {
            FileHandle.standardError.write(Data(($0 + "\n").utf8))
        }
    ) -> Int32 {
        guard let request = parse(arguments) else {
            errorOutput(usage)
            return 2
        }
        guard let message = request.message, !message.isEmpty else {
            errorOutput("devhq: --message is required")
            return 1
        }

        let store = CommentStore(environment: environment)
        var match: (fileURL: URL, threads: [CommentThread], index: Int)?
        for fileURL in store.allCommentsFileURLs() {
            let threads = store.loadThreads(from: fileURL)
            for (index, thread) in threads.enumerated() where thread.id == request.commentID {
                if match != nil {
                    errorOutput("devhq: comment id is ambiguous: \(request.commentID)")
                    return 1
                }
                match = (fileURL, threads, index)
            }
        }
        guard let match else {
            errorOutput("devhq: comment not found: \(request.commentID)")
            return 1
        }
        let fileURL = match.fileURL
        var threads = match.threads
        let index = match.index

        let now = CommentClock.timestamp()
        var thread = threads[index]
        let replyID = "\(thread.id):reply:\(thread.messages.count + 1)"
        let agentID = environment["AGENT_ID"].flatMap { $0.isEmpty ? nil : $0 }
        thread.messages.append(
            CommentMessage(
                author: .agent,
                body: message,
                state: .open,
                createdAt: now,
                updatedAt: now,
                id: replyID,
                agentID: agentID
            )
        )
        thread.updatedAt = now
        threads[index] = thread

        let worktreePath = store.metaWorktreePath(of: fileURL) ?? thread.worktree
        do {
            try store.save(threads, worktreePath: worktreePath, to: fileURL)
        } catch {
            errorOutput("devhq: cannot replace \(fileURL.path): \(error.localizedDescription)")
            return 1
        }
        output(replyID)
        return 0
    }

    private struct Request {
        let commentID: String
        let message: String?
    }

    private static func parse(_ arguments: [String]) -> Request? {
        guard arguments.count > 3,
              arguments[1] == "review",
              arguments[2] == "reply" else {
            return nil
        }
        let commentID = arguments[3]
        var message: String?
        var index = 4
        while index < arguments.count {
            guard arguments[index] == "--message",
                  message == nil,
                  index + 1 < arguments.count else {
                return nil
            }
            message = arguments[index + 1]
            index += 2
        }
        return Request(commentID: commentID, message: message)
    }
}

@main
enum DevHQMain {
    static func main() {
        ValidationAppBundle.reexecIfRequested()
        let arguments = CommandLine.arguments
        if ReviewReplyCLI.isReviewInvocation(arguments) {
            exit(ReviewReplyCLI.run(arguments: arguments))
        }
        DevHQApp.main()
    }
}
