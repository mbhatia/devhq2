import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import XCTest
@testable import DevHQ

@MainActor
final class DiffEditorPresentationTests: XCTestCase {
    func testPreparingCoordinatorBeforeControllerLoadsViewDoesNotAccessScrollView() {
        let coordinator = DiffEditorCoordinator()
        let language = CodeLanguage.detectLanguageFrom(
            url: URL(fileURLWithPath: "/tmp/File.swift"),
            prefixBuffer: "",
            suffixBuffer: ""
        )

        let controller = TextViewController(
            string: "",
            language: language,
            configuration: SourceEditorView.configuration(isDark: false),
            cursorPositions: [],
            highlightProviders: [],
            coordinators: [coordinator]
        )

        XCTAssertNil(controller.scrollView)
    }

    func testOverlayUsesFramePlacementWithoutChangingContainerLayout() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let originalFrame = container.frame
        let originalFittingSize = container.fittingSize
        let coordinator = DiffEditorCoordinator()

        coordinator.presentOverlay(makeHunk(longLine: true), in: container)
        container.layoutSubtreeIfNeeded()

        let overlay = try XCTUnwrap(coordinator.overlayView)
        XCTAssertEqual(container.frame, originalFrame)
        XCTAssertEqual(container.fittingSize, originalFittingSize)
        XCTAssertTrue(overlay.translatesAutoresizingMaskIntoConstraints)
        XCTAssertTrue(container.bounds.contains(overlay.frame))
        XCTAssertLessThanOrEqual(overlay.frame.width, 760)
        XCTAssertLessThanOrEqual(overlay.frame.height, 420)
    }

    func testOutsideClickAndEscapeDismissOverlay() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let container = try XCTUnwrap(window.contentView)
        let coordinator = DiffEditorCoordinator()
        coordinator.presentOverlay(makeHunk(), in: container)
        let overlay = try XCTUnwrap(coordinator.overlayView)

        let insidePoint = overlay.convert(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY), to: nil)
        let insideClick = try XCTUnwrap(mouseEvent(at: insidePoint, in: window))
        XCTAssertNotNil(coordinator.handleOverlayEvent(insideClick))
        XCTAssertNotNil(coordinator.overlayView)

        let outsidePoint = container.convert(NSPoint(x: 2, y: 2), to: nil)
        let outsideClick = try XCTUnwrap(mouseEvent(at: outsidePoint, in: window))
        XCTAssertNotNil(coordinator.handleOverlayEvent(outsideClick))
        XCTAssertNil(coordinator.overlayView)

        coordinator.presentOverlay(makeHunk(), in: container)
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let otherWindowEscape = try XCTUnwrap(escapeEvent(in: otherWindow))
        XCTAssertNotNil(coordinator.handleOverlayEvent(otherWindowEscape))
        XCTAssertNotNil(coordinator.overlayView)

        let escape = try XCTUnwrap(escapeEvent(in: window))
        XCTAssertNil(coordinator.handleOverlayEvent(escape))
        XCTAssertNil(coordinator.overlayView)
    }

    private func escapeEvent(in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )
    }

    func testLateResultCannotReplaceNewContext() async throws {
        let loader = ControlledDiffLoader()
        let presentation = DiffEditorPresentation()
        let oldContext = context(text: "old")
        let newContext = context(text: "new")
        let oldConfiguration = configuration(context: oldContext, loader: loader)
        let newConfiguration = configuration(context: newContext, loader: loader)

        let oldTask = Task { await presentation.load(oldConfiguration) }
        await loader.waitForRequest(text: "old")
        let newTask = Task { await presentation.load(newConfiguration) }
        await loader.waitForRequest(text: "new")

        await loader.complete(text: "new", status: "new result")
        await newTask.value
        XCTAssertEqual(presentation.statusMessage, "new result")

        await loader.complete(text: "old", status: "stale result")
        await oldTask.value
        XCTAssertEqual(presentation.statusMessage, "new result")
    }

    func testContextChangeClearsPresentationBeforeAwaitAndRejectsLateResult() async {
        let loader = ControlledDiffLoader()
        let presentation = DiffEditorPresentation()
        let initialContext = context(text: "initial")
        await presentation.load(.init(isEnabled: true, context: initialContext) { _ in
            DiffEditorSnapshot(
                markers: [.init(line: 1, kind: .added, hunkID: "initial")],
                statusMessage: "initial result"
            )
        })
        XCTAssertFalse(presentation.snapshot.markers.isEmpty)

        let oldContext = context(text: "old pending")
        let oldTask = Task {
            await presentation.load(configuration(context: oldContext, loader: loader))
        }
        await loader.waitForRequest(text: oldContext.currentText)

        XCTAssertEqual(presentation.snapshot, DiffEditorSnapshot())
        XCTAssertNil(presentation.statusMessage)

        let newContext = context(text: "new pending")
        let newTask = Task {
            await presentation.load(configuration(context: newContext, loader: loader))
        }
        await loader.waitForRequest(text: newContext.currentText)

        await loader.complete(text: oldContext.currentText, status: "late result")
        await oldTask.value
        XCTAssertEqual(presentation.snapshot, DiffEditorSnapshot())
        XCTAssertNil(presentation.statusMessage)

        await loader.complete(text: newContext.currentText, status: "current result")
        await newTask.value
        XCTAssertEqual(presentation.statusMessage, "current result")
    }

    func testEveryContextDimensionChangesRequestIdentity() {
        let base = context(text: "text")
        let variants = [
            DiffEditorContext(
                projectURL: URL(fileURLWithPath: "/other"),
                fileURL: base.fileURL,
                filterIdentity: base.filterIdentity,
                currentText: base.currentText
            ),
            DiffEditorContext(
                projectURL: base.projectURL,
                fileURL: URL(fileURLWithPath: "/repo/other.swift"),
                filterIdentity: base.filterIdentity,
                currentText: base.currentText
            ),
            DiffEditorContext(
                projectURL: base.projectURL,
                fileURL: base.fileURL,
                filterIdentity: "staged",
                currentText: base.currentText
            ),
            DiffEditorContext(
                projectURL: base.projectURL,
                fileURL: base.fileURL,
                filterIdentity: base.filterIdentity,
                currentText: "unsaved edit"
            ),
            DiffEditorContext(
                projectURL: base.projectURL,
                fileURL: base.fileURL,
                filterIdentity: base.filterIdentity,
                currentText: base.currentText,
                comparisonRevision: "abc123"
            ),
            DiffEditorContext(
                projectURL: base.projectURL,
                fileURL: base.fileURL,
                filterIdentity: base.filterIdentity,
                currentText: base.currentText,
                historicalContext: .init(
                    commitID: "commit",
                    parentCommitID: "parent",
                    oldPath: "old.swift",
                    newPath: "new.swift"
                )
            )
        ]

        for variant in variants {
            XCTAssertNotEqual(base, variant)
        }
    }

    func testDisablingClearsPresentationWithoutOwningDocumentText() async {
        let context = context(text: "live document text")
        let presentation = DiffEditorPresentation()
        let enabled = DiffEditorConfiguration(isEnabled: true, context: context) { _ in
            DiffEditorSnapshot(
                markers: [.init(line: 1, kind: .modified, hunkID: "hunk")],
                statusMessage: "shown"
            )
        }

        await presentation.load(enabled)
        XCTAssertEqual(presentation.snapshot.markers.count, 1)

        await presentation.load(.init(isEnabled: false, context: context, load: enabled.load))
        XCTAssertEqual(presentation.snapshot, DiffEditorSnapshot())
        XCTAssertEqual(context.currentText, "live document text")
    }

    func testSnapshotRetainsCompleteHunkPresentation() async {
        let hunk = DiffEditorHunk(
            id: "hunk",
            metadata: ["diff --git a/file b/file", "index 123..456"],
            header: "@@ -1,3 +1,3 @@",
            lines: [
                .init(kind: .context, text: " unchanged"),
                .init(kind: .deletion, text: "-old"),
                .init(kind: .addition, text: "+new")
            ]
        )
        let snapshot = DiffEditorSnapshot(
            markers: [
                .init(line: 1, kind: .added, hunkID: hunk.id),
                .init(line: 2, kind: .modified, hunkID: hunk.id),
                .init(line: 3, kind: .deleted, hunkID: hunk.id)
            ],
            hunks: [hunk]
        )
        let presentation = DiffEditorPresentation()

        await presentation.load(.init(isEnabled: true, context: context(text: "new")) { _ in snapshot })

        XCTAssertEqual(presentation.snapshot, snapshot)
        XCTAssertEqual(presentation.snapshot.hunks.first?.lines.count, 3)
        XCTAssertEqual(Set(presentation.snapshot.markers.map(\.kind)), [.added, .modified, .deleted])
    }

    private func context(text: String) -> DiffEditorContext {
        DiffEditorContext(
            projectURL: URL(fileURLWithPath: "/repo"),
            fileURL: URL(fileURLWithPath: "/repo/file.swift"),
            filterIdentity: "full",
            currentText: text
        )
    }

    private func configuration(
        context: DiffEditorContext,
        loader: ControlledDiffLoader
    ) -> DiffEditorConfiguration {
        DiffEditorConfiguration(isEnabled: true, context: context) { context in
            try await loader.load(context)
        }
    }

    private func makeHunk(longLine: Bool = false) -> DiffEditorHunk {
        DiffEditorHunk(
            id: "hunk",
            metadata: ["--- a/file", "+++ b/file"],
            header: "@@ -1 +1 @@",
            lines: [
                .init(kind: .deletion, text: "-old"),
                .init(
                    kind: .addition,
                    text: longLine ? "+" + String(repeating: "new", count: 500) : "+new"
                )
            ]
        )
    }

    private func mouseEvent(at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
    }
}

private actor ControlledDiffLoader {
    private var continuations: [String: CheckedContinuation<DiffEditorSnapshot, Error>] = [:]

    func load(_ context: DiffEditorContext) async throws -> DiffEditorSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            continuations[context.currentText] = continuation
        }
    }

    func waitForRequest(text: String) async {
        while continuations[text] == nil {
            await Task.yield()
        }
    }

    func complete(text: String, status: String) {
        continuations.removeValue(forKey: text)?.resume(
            returning: DiffEditorSnapshot(statusMessage: status)
        )
    }
}
