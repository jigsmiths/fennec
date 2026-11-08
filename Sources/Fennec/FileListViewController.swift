import AppKit
import FennecCore

final class FileTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onQuickLook: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if !handleFolderKey(event, onOpen: onOpen, onQuickLook: onQuickLook) {
            super.keyDown(with: event)
        }
    }
}

/// Return opens and space toggles Quick Look, but only without modifiers so menu shortcuts still work.
@MainActor
func handleFolderKey(_ event: NSEvent, onOpen: (() -> Void)?, onQuickLook: (() -> Void)?) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad]).isEmpty
    else { return false }
    switch event.keyCode {
    case 36, 76:
        onOpen?()
        return true
    case 49:
        onQuickLook?()
        return true
    default:
        return false
    }
}

@MainActor
final class FileListViewController: NSViewController, FolderContentView, NSTableViewDataSource, NSTableViewDelegate {
    var onOpen: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onSortChange: ((FennecCore.SortOrder) -> Void)?
    var sortOrder = FennecCore.SortOrder()

    private let tableView = FileTableView()
    private let scrollView = NSScrollView()
    private var rows: [FileEntry] = []

    override func loadView() {
        let columns: [(SortKey, String, CGFloat)] = [
            (.name, "Name", 380), (.size, "Size", 90), (.modified, "Modified", 180), (.kind, "Kind", 160),
        ]
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: .init(key.rawValue))
            column.title = title
            column.width = width
            column.minWidth = key == .name ? 140 : 60
            column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            if key == .size { column.headerCell.alignment = .right }
            tableView.addTableColumn(column)
        }
        tableView.style = .inset
        tableView.rowHeight = 24
        tableView.allowsMultipleSelection = true
        // Uniform resizing: with first-column-only, Name kept all the width and pushed the other columns off-screen.
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.sortDescriptors = [NSSortDescriptor(key: sortOrder.key.rawValue, ascending: sortOrder.ascending)]
        tableView.autosaveName = "FileListColumns"
        tableView.autosaveTableColumns = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        tableView.onOpen = { [weak self] in self?.onOpen?() }
        tableView.onQuickLook = { [weak self] in self?.onQuickLook?() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        view = scrollView
    }

    // MARK: FolderContentView

    var selectedIndexes: IndexSet { tableView.selectedRowIndexes }

    func display(_ newRows: [FileEntry], selecting indexes: IndexSet, keepScroll: Bool) {
        loadViewIfNeeded()
        let scrollOrigin = scrollView.contentView.bounds.origin
        rows = newRows
        tableView.reloadData()
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)

        if keepScroll {
            scrollView.contentView.scroll(to: scrollOrigin)
        } else if let first = indexes.first {
            tableView.scrollRowToVisible(first)
        } else {
            tableView.scrollRowToVisible(0)
        }
    }

    func focus() {
        view.window?.makeFirstResponder(tableView)
    }

    func handleKey(_ event: NSEvent) {
        tableView.keyDown(with: event)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        onOpen?()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key.flatMap(SortKey.init(rawValue:)) else { return }
        sortOrder = FennecCore.SortOrder(key: key, ascending: descriptor.ascending)
        onSortChange?(sortOrder)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn == nil || tableColumn?.identifier.rawValue == SortKey.name.rawValue else { return nil }
        return rows[row].name
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let key = SortKey(rawValue: id) else { return nil }
        let entry = rows[row]

        if key == .name {
            let cell = tableView.makeView(withIdentifier: FileNameCell.reuseID, owner: self) as? FileNameCell
                ?? FileNameCell()
            cell.configure(entry)
            return cell
        }

        let cell = tableView.makeView(withIdentifier: TextCell.reuseID, owner: self) as? TextCell ?? TextCell()
        switch key {
        case .size: cell.set(FileDisplay.size(for: entry), alignment: .right)
        case .modified: cell.set(FileDisplay.date(entry.modified), alignment: .left)
        case .kind: cell.set(FileDisplay.kind(for: entry), alignment: .left)
        case .name: break
        }
        cell.alphaValue = entry.isHidden ? 0.55 : 1
        return cell
    }
}

@MainActor
final class FileNameCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("name")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let cloudBadge = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        imageView = icon
        textField = label

        label.lineBreakMode = .byTruncatingMiddle
        cloudBadge.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "Not downloaded")
        cloudBadge.contentTintColor = .secondaryLabelColor
        [icon, label, cloudBadge].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let height = bounds.height
        icon.frame = NSRect(x: 2, y: (height - 18) / 2, width: 18, height: 18)
        let badgeWidth: CGFloat = cloudBadge.isHidden ? 0 : 20
        let labelX: CGFloat = 26
        let labelHeight = label.cell?.cellSize.height ?? 16
        label.frame = NSRect(x: labelX, y: (height - labelHeight) / 2,
                             width: max(0, bounds.width - labelX - badgeWidth - 4), height: labelHeight)
        cloudBadge.frame = NSRect(x: bounds.width - badgeWidth, y: (height - 16) / 2, width: 16, height: 16)
    }

    func configure(_ entry: FileEntry) {
        icon.image = FileDisplay.icon(for: entry)
        label.stringValue = entry.name
        cloudBadge.isHidden = entry.cloudStatus != .notDownloaded
        alphaValue = entry.isHidden ? 0.55 : 1
        needsLayout = true
    }
}

@MainActor
final class TextCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("text")

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        textField = label
        label.textColor = .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let labelHeight = label.cell?.cellSize.height ?? 16
        label.frame = NSRect(x: 2, y: (bounds.height - labelHeight) / 2,
                             width: max(0, bounds.width - 6), height: labelHeight)
    }

    func set(_ text: String, alignment: NSTextAlignment) {
        label.stringValue = text
        label.alignment = alignment
    }
}
