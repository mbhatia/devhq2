import XCTest
@testable import DevHQ

final class GitDiffParserTests: XCTestCase {
    func testParsesHunkLinesNumbersMetadataAndReplacementMarkers() {
        let diff = """
        diff --git a/Sources/File.swift b/Sources/File.swift
        index 1111111..2222222 100644
        --- a/Sources/File.swift
        +++ b/Sources/File.swift
        @@ -10,4 +10,5 @@ func example() {
         unchanged
        -old one
        -old two
        +new one
        +new two
        +new three
         trailing
        """

        let result = GitDiffParser.parse(
            diff,
            contextID: "request",
            fallbackPath: "fallback.swift",
            parentState: .resolved(reference: "origin/main", mergeBase: "abc")
        )

        XCTAssertEqual(result.contextID, "request")
        XCTAssertEqual(result.oldPath, "Sources/File.swift")
        XCTAssertEqual(result.newPath, "Sources/File.swift")
        XCTAssertEqual(result.parentState, .resolved(reference: "origin/main", mergeBase: "abc"))
        XCTAssertFalse(result.isBinary)
        XCTAssertEqual(result.hunks.count, 1)

        let hunk = try! XCTUnwrap(result.hunks.first)
        XCTAssertEqual(hunk.id, "request:0")
        XCTAssertEqual(hunk.header, "@@ -10,4 +10,5 @@ func example() {")
        XCTAssertEqual(hunk.oldStart, 10)
        XCTAssertEqual(hunk.oldCount, 4)
        XCTAssertEqual(hunk.newStart, 10)
        XCTAssertEqual(hunk.newCount, 5)
        XCTAssertEqual(Array(hunk.lines.prefix(4).map(\.kind)), Array(repeating: .metadata, count: 4))

        let semantic = hunk.lines.filter { $0.kind != .metadata }
        XCTAssertEqual(semantic.map(\.kind), [.context, .deletion, .deletion, .addition, .addition, .addition, .context])
        XCTAssertEqual(semantic.map(\.oldLineNumber), [10, 11, 12, nil, nil, nil, 13])
        XCTAssertEqual(semantic.map(\.newLineNumber), [10, nil, nil, 11, 12, 13, 14])
        XCTAssertEqual(result.markers.map(\.line), [11, 12, 13])
        XCTAssertEqual(result.markers.map(\.kind), [.modified, .modified, .modified])
        XCTAssertTrue(result.markers.allSatisfy { $0.hunkID == hunk.id })
    }

    func testAdditionOnlyAndDeletionOnlyMarkersUseSurvivingLines() {
        let diff = """
        --- a/file.txt
        +++ b/file.txt
        @@ -1,2 +1,3 @@
         first
        +inserted
         second
        @@ -8,3 +9,2 @@
         before
        -removed
         after
        @@ -20,2 +20,1 @@
         last surviving
        -removed at eof
        """

        let result = GitDiffParser.parse(diff, contextID: "markers", fallbackPath: "file.txt")

        XCTAssertEqual(result.markers.map(\.kind), [.added, .deleted, .deleted])
        XCTAssertEqual(result.markers.map(\.line), [2, 10, 20])
        XCTAssertEqual(Set(result.markers.map(\.hunkID)), ["markers:0", "markers:1", "markers:2"])
    }

    func testRetainsNoNewlineMarkerAsMetadataWithoutChangingLineNumbers() {
        let diff = """
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """

        let result = GitDiffParser.parse(diff, contextID: "newline", fallbackPath: "file.txt")
        let hunk = try! XCTUnwrap(result.hunks.first)
        let semantic = hunk.lines.filter { $0.kind != .metadata }

        XCTAssertEqual(hunk.lines.filter { $0.text == "\\ No newline at end of file" }.count, 2)
        XCTAssertEqual(semantic.map(\.oldLineNumber), [1, nil])
        XCTAssertEqual(semantic.map(\.newLineNumber), [nil, 1])
        XCTAssertEqual(result.markers.map(\.kind), [.modified])
        XCTAssertEqual(result.markers.map(\.line), [1])
    }

    func testRenameAndCopyMetadataOverrideHeaderPaths() {
        let renamed = GitDiffParser.parse(
            """
            diff --git a/old name.txt b/new name.txt
            similarity index 100%
            rename from old name.txt
            rename to new name.txt
            """,
            contextID: "rename",
            fallbackPath: "fallback"
        )
        XCTAssertEqual(renamed.oldPath, "old name.txt")
        XCTAssertEqual(renamed.newPath, "new name.txt")

        let copied = GitDiffParser.parse(
            """
            similarity index 100%
            copy from source.txt
            copy to destination.txt
            """,
            contextID: "copy",
            fallbackPath: "fallback"
        )
        XCTAssertEqual(copied.oldPath, "source.txt")
        XCTAssertEqual(copied.newPath, "destination.txt")
    }

    func testDetectsBinaryDiffAndHandlesAddedOrDeletedFiles() {
        let added = GitDiffParser.parse(
            """
            diff --git a/image.png b/image.png
            new file mode 100644
            Binary files /dev/null and b/image.png differ
            """,
            contextID: "binary",
            fallbackPath: "image.png"
        )
        XCTAssertTrue(added.isBinary)
        XCTAssertEqual(added.oldPath, "image.png")
        XCTAssertEqual(added.newPath, "image.png")
        XCTAssertTrue(added.hunks.isEmpty)
        XCTAssertTrue(added.markers.isEmpty)

        let deleted = GitDiffParser.parse(
            """
            --- a/deleted.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -gone
            """,
            contextID: "deleted",
            fallbackPath: "deleted.txt"
        )
        XCTAssertEqual(deleted.oldPath, "deleted.txt")
        XCTAssertEqual(deleted.newPath, "deleted.txt")
        XCTAssertEqual(deleted.markers.map(\.line), [1])
        XCTAssertEqual(deleted.markers.map(\.kind), [.deleted])
    }

    func testDataAPIUsesLossyUTF8AndKeepsFallbackForEmptyDiff() {
        let result = GitDiffParser.parse(
            Data([0xff]),
            contextID: "data",
            fallbackPath: "fallback.txt",
            parentState: .noParent(message: "No parent")
        )

        XCTAssertEqual(result.newPath, "fallback.txt")
        XCTAssertEqual(result.parentState, .noParent(message: "No parent"))
        XCTAssertTrue(result.hunks.isEmpty)
        XCTAssertTrue(result.markers.isEmpty)
    }
}
