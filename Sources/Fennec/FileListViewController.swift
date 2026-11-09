import AppKit
import FennecCore

final class FileTableView: NSTableView {
    var onRename: (() -> Void)?
    var onQuickLook: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if !handleFolderKey(event, onRename: onRename, onQuickLook: onQuickLook) {
            super.keyDown(with: event)
        }
    }
}

/// Return renames (like Finder) and space toggles Quick Look, but only without modifiers so menu shortcuts still work.
@MainActor
func handleFolderKey(_ event: NSEvent, onRename: (() -> Void)?, onQuickLook: (() -> Void)?) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad]).isEmpty
    else { return false }
    switch event.keyCode {
    case 36, 76:
        onRename?()
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
    var onRename: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onQuickLook: (() -> Void)?
    weak var dropHandler: FolderDropHandler?
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
        tableView.autosaveName = "FileListColumns"
        tableView.autosaveTableColumns = true
        // Set after autosave, which restores its own saved sort indicator; the folder's sort order is the source of truth.
        tableView.sortDescriptors = [NSSortDescriptor(key: sortOrder.key.rawValue, ascending: sortOrder.ascending)]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        tableView.onRename = { [weak self] in self?.onRename?() }
        tableView.onQuickLook = { [weak self] in self?.onQuickLook?() }
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)

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
        let update = {
            self.replaceRows(with: newRows)
            self.tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        if keepScroll {
            scrollView.keepingScrollPosition(update)
            return
        }
        update()
        if let first = indexes.first {
            tableView.scrollRowToVisible(first)
        } else {
            tableView.scrollRowToVisible(0)
        }
    }

    /// reloadData() throws away every row and cell view, so each reload rebuilt ~45 rows from scratch.
    /// Adjusting the row count and refreshing rows in place keeps the existing views and reuses them.
    private func replaceRows(with newRows: [FileEntry]) {
        let oldCount = rows.count
        rows = newRows
        if newRows.count > oldCount {
            tableView.insertRows(at: IndexSet(oldCount..<newRows.count), withAnimation: [])
        } else if newRows.count < oldCount {
            tableView.removeRows(at: IndexSet(newRows.count..<oldCount), withAnimation: [])
        }
        let common = min(oldCount, newRows.count)
        if common > 0 {
            tableView.reloadData(forRowIndexes: IndexSet(0..<common),
                                 columnIndexes: IndexSet(0..<tableView.numberOfColumns))
        }
    }

    func focus() {
        view.window?.makeFirstResponder(tableView)
    }

    func handleKey(_ event: NSEvent) {
        tableView.keyDown(with: event)
    }

    func beginRename(at index: Int, onEnd: @escaping (String?) -> Void) {
        let column = tableView.column(withIdentifier: .init(SortKey.name.rawValue))
        guard index < rows.count, column >= 0 else { return onEnd(nil) }
        tableView.scrollRowToVisible(index)
        guard let cell = tableView.view(atColumn: column, row: index, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return onEnd(nil) }
        InlineRename.begin(
            on: field, name: rows[index].name, isFolder: rows[index].isBrowsable,
            returnFocusTo: tableView, onEnd: onEnd)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        onOpen?()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        rows[row].url as NSURL
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let folder = dropFolder(row: row, operation: dropOperation)
        // Anywhere that isn't a folder row drops into the folder being shown, so highlight the whole list.
        if folder == nil { tableView.setDropRow(-1, dropOperation: .on) }
        return dropHandler?.validateDrop(info, onto: folder) ?? []
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        dropHandler?.acceptDrop(info, onto: dropFolder(row: row, operation: dropOperation)) ?? false
    }

    private func dropFolder(row: Int, operation: NSTableView.DropOperation) -> FileEntry? {
        guard operation == .on, row >= 0, row < rows.count, rows[row].isBrowsable else { return nil }
        return rows[row]
    }

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
        case .size: cell.set(FileFormatting.size(for: entry), alignment: .right)
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
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cloudBadge.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "Not downloaded")
        cloudBadge.contentTintColor = .secondaryLabelColor

        for view in [icon, label, cloudBadge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudBadge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            cloudBadge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            cloudBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ entry: FileEntry) {
        icon.image = FileDisplay.icon(for: entry)
        label.stringValue = entry.name
        cloudBadge.isHidden = entry.cloudStatus != .notDownloaded
        alphaValue = entry.isHidden ? 0.55 : 1
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
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ text: String, alignment: NSTextAlignment) {
        label.stringValue = text
        label.alignment = alignment
    }
}
