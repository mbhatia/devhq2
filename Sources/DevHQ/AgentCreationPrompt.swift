import AppKit
import Foundation

@MainActor
final class AgentProfileListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let profileNames: [String]

    init(profileNames: [String]) {
        self.profileNames = profileNames.sorted()
        super.init()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        profileNames.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("agent-create-profile-row")
        let cell: NSTextField
        if let reusedCell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            cell = reusedCell
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.lineBreakMode = .byTruncatingTail
        }
        cell.stringValue = profileNames[row]
        return cell
    }

    func selectedProfile(in tableView: NSTableView) -> String? {
        guard profileNames.indices.contains(tableView.selectedRow) else { return nil }
        return profileNames[tableView.selectedRow]
    }
}

struct AgentCreationRequest: Equatable {
    let profile: String
    let name: String
}

@MainActor
struct AgentCreationPrompt {
    let present: (_ profileNames: [String]) -> AgentCreationRequest?

    @MainActor
    struct Form {
        let view: NSView
        let profileScrollView: NSScrollView
        let profileTable: NSTableView
        let nameField: NSTextField
        let profileListController: AgentProfileListController

        var selectedProfile: String? {
            profileListController.selectedProfile(in: profileTable)
        }
    }

    static func makeForm(profileNames: [String]) -> Form {
        let formWidth: CGFloat = 340
        let labelWidth: CGFloat = 68
        let controlX: CGFloat = 80
        let controlWidth = formWidth - controlX
        let controlHeight: CGFloat = 26
        let view = NSView(frame: NSRect(x: 0, y: 0, width: formWidth, height: 110))
        view.setAccessibilityIdentifier("agent-create-form")

        let profileLabel = NSTextField(labelWithString: "Profile:")
        profileLabel.alignment = .right
        profileLabel.frame = NSRect(x: 0, y: 85, width: labelWidth, height: 20)

        let profileListController = AgentProfileListController(profileNames: profileNames)
        let tableHeight = max(CGFloat(profileListController.profileNames.count) * 22, 74)
        let profileTable = NSTableView(
            frame: NSRect(x: 0, y: 0, width: controlWidth, height: tableHeight)
        )
        let profileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        profileColumn.width = controlWidth
        profileTable.addTableColumn(profileColumn)
        profileTable.headerView = nil
        profileTable.rowHeight = 22
        profileTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        profileTable.autoresizingMask = [.width]
        profileTable.allowsEmptySelection = false
        profileTable.allowsMultipleSelection = false
        profileTable.allowsTypeSelect = true
        profileTable.dataSource = profileListController
        profileTable.delegate = profileListController
        profileTable.setAccessibilityIdentifier("agent-create-profile")
        profileTable.setAccessibilityLabel("Profiles")
        profileTable.reloadData()
        if !profileListController.profileNames.isEmpty {
            profileTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        let profileScrollView = NSScrollView(
            frame: NSRect(x: controlX, y: 31, width: controlWidth, height: 76)
        )
        profileScrollView.borderType = .bezelBorder
        profileScrollView.hasVerticalScroller = true
        profileScrollView.autohidesScrollers = true
        profileScrollView.documentView = profileTable
        profileScrollView.setAccessibilityIdentifier("agent-create-profile-list-container")
        let profileContentWidth = profileScrollView.contentSize.width
        profileTable.setFrameSize(NSSize(width: profileContentWidth, height: tableHeight))
        profileTable.sizeLastColumnToFit()
        profileColumn.resizingMask = .autoresizingMask

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.alignment = .right
        nameLabel.frame = NSRect(x: 0, y: 4, width: labelWidth, height: 20)

        let nameField = NSTextField(
            frame: NSRect(x: controlX, y: 0, width: controlWidth, height: controlHeight)
        )
        nameField.placeholderString = "Agent name"
        nameField.setAccessibilityIdentifier("agent-create-name")

        view.addSubview(profileLabel)
        view.addSubview(profileScrollView)
        view.addSubview(nameLabel)
        view.addSubview(nameField)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        return Form(
            view: view,
            profileScrollView: profileScrollView,
            profileTable: profileTable,
            nameField: nameField,
            profileListController: profileListController
        )
    }

    static let appKit = AgentCreationPrompt { profileNames in
        guard !profileNames.isEmpty else { return nil }

        let form = makeForm(profileNames: profileNames)

        let alert = NSAlert()
        alert.messageText = "Create Agent"
        alert.informativeText = "Choose an agent profile and enter a name."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = form.view
        alert.window.initialFirstResponder = form.nameField

        while alert.runModal() == .alertFirstButtonReturn {
            let name = form.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, let profile = form.selectedProfile {
                return AgentCreationRequest(profile: profile, name: name)
            }
            alert.informativeText = "Agent name must not be empty."
            alert.window.initialFirstResponder = form.nameField
        }
        return nil
    }
}
