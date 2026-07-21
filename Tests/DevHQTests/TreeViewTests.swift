import XCTest
@testable import DevHQ

final class TreeViewTests: XCTestCase {
    func testFoldsMaximalSingleContainerChainWithoutChangingSourceTree() throws {
        let file = TreeNode(id: "folder1/folder2/file.swift", value: "file.swift", children: nil)
        let folder2 = TreeNode(id: "folder1/folder2", value: "folder2", children: [file])
        let folder1 = TreeNode(id: "folder1", value: "folder1", children: [folder2])

        let rows = foldedTreeNodes([folder1], isContainer: { $0.isBranch })

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.nodes.map(\.id), ["folder1", "folder1/folder2"])
        XCTAssertEqual(row.id, folder1.id)
        XCTAssertEqual(row.terminal.id, folder2.id)
        XCTAssertEqual(row.children?.map(\.id), [file.id])
        XCTAssertEqual(folder1.children?.first?.id, folder2.id)
    }

    func testDoesNotFoldAcrossLeafOrMultipleChildren() throws {
        let onlyFile = TreeNode(id: "only/file", value: "file", children: nil)
        let singleFileFolder = TreeNode(id: "only", value: "only", children: [onlyFile])
        let firstFolder = TreeNode<String, String>(id: "first", value: "first", children: [])
        let secondFolder = TreeNode<String, String>(id: "second", value: "second", children: [])
        let multipleFolders = TreeNode(
            id: "multiple",
            value: "multiple",
            children: [firstFolder, secondFolder]
        )

        let rows = foldedTreeNodes(
            [singleFileFolder, multipleFolders],
            isContainer: { $0.isBranch }
        )

        XCTAssertEqual(rows[0].nodes.map(\.id), [singleFileFolder.id])
        XCTAssertEqual(rows[1].nodes.map(\.id), [multipleFolders.id])
    }

    func testSemanticContainerFoldsWorktreeWithoutMaterializedChildren() throws {
        let worktree = TreeNode(id: "main", value: "worktree", children: nil)
        let repository = TreeNode(id: "devhq", value: "repository", children: [worktree])

        let row = try XCTUnwrap(foldedTreeNodes(
            [repository],
            isContainer: { $0.value != "agent" }
        ).first)

        XCTAssertEqual(row.nodes.map(\.id), ["devhq", "main"])
        XCTAssertEqual(row.terminal.id, worktree.id)
        XCTAssertNil(row.children)
    }

    func testFoldedRowCombinesContextMenusAndUsesTerminalDuplicate() throws {
        let worktree = TreeNode(id: "main", value: "worktree", children: nil)
        let repository = TreeNode(id: "devhq", value: "repository", children: [worktree])
        let row = try XCTUnwrap(foldedTreeNodes(
            [repository],
            isContainer: { _ in true }
        ).first)

        let entries = mergedTreeContextMenuEntries(for: row) { node in
            if node.id == "devhq" {
                return [
                    TreeContextMenuEntry(id: "shared", title: "Repository Action", action: {}),
                    TreeContextMenuEntry(id: "create", title: "Create Worktree", action: {})
                ]
            }
            return [
                TreeContextMenuEntry(id: "shared", title: "Worktree Action", action: {}),
                TreeContextMenuEntry(id: "delete", title: "Delete Worktree", action: {})
            ]
        }

        XCTAssertEqual(entries.map(\.id), ["shared", "create", "delete"])
        XCTAssertEqual(entries.first?.title, "Worktree Action")
    }
}
