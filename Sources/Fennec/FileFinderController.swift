import AppKit
import FennecCore
import UniformTypeIdentifiers

/// A floating search box over the window that fuzzy-finds everything under a folder, like fzf.
/// Return shows the pick in its folder; Cmd+Return opens it.
@MainActor
final class FileFinderController: NSObject {
    /// The user picked an item; `open` is true for Cmd+Return.
    var onChoose: ((_ url: URL, _ isBrowsable: Bool, _ open: Bool) -> Void)?

    private static let resultLimit = 200
    private static let rowHeight: CGFloat = 38

    private let index: FinderIndex
    private var root: URL { index.root }
    /// The searched folder relative to the index root; "" is the root itself.
    private let folder: String
    /// UTF-16 length of `folder` plus its slash, hidden from every shown path.
    private let skip: Int
    private var listener: UUID?
    private var scopeCount = 0
    private let panel = FinderPanel()
    private let field = NSTextField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")

    /// The shown rows. Items are copied out so a refresh replacing the index can't shift them.
    private var results: [(item: FileIndexer.Item, match: FuzzyMatcher.Match)] = []
    private var matchCount = 0
    /// The last search, to narrow the next one while the user keeps typing.
    private var searchState: FuzzyMatcher.SearchState?
    private var searchStateVersion = -1
    private var searchGeneration = 0
    private var lastSearch = ContinuousClock.now
    private var isClosed = false
    /// Arrow keys moved the selection since the query last changed.
    private var userMovedSelection = false
    private var iconsByExtension: [String: NSImage] = [:]
    private let folderIcon = NSWorkspace.shared.icon(for: .folder)

    init(index: FinderIndex, folder: String) {
        self.index = index
        self.folder = folder
        skip = folder.isEmpty ? 0 : folder.utf16.count + 1
        super.init()
        buildPanel()
    }

    func show(over parent: NSWindow) {
        let width = min(640, parent.frame.width - 40)
        let height = panel.frame.height
        panel.setFrame(NSRect(x: parent.frame.midX - width / 2, y: parent.frame.maxY - 90 - height,
                              width: width, height: height), display: false)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        listener = index.addListener { [weak self] in self?.indexUpdated() }
        index.refreshIfNeeded()
        search()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let listener { index.removeListener(listener) }
        searchGeneration += 1
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
        results = []
        // The table may still have a layout pending for the old rows.
        table.reloadData()
    }

    // MARK: Searching

    private func indexUpdated() {
        // Re-rank as a first walk streams in, but not for every batch on a big tree.
        if !index.isWalking || ContinuousClock.now - lastSearch > .milliseconds(150) { search() }
    }

    private func search() {
        guard !isClosed else { return }
        searchGeneration += 1
        let generation = searchGeneration
        lastSearch = .now
        let query = FuzzyMatcher.Query(field.stringValue)
        let items = index.items, candidates = index.candidates, version = index.version
        let scope = index.scope(forRelativePath: folder)
        scopeCount = scope?.indices.count ?? candidates.count
        let previous = searchStateVersion == version ? searchState : nil
        let limit = Self.resultLimit
        updateStatus()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                FuzzyMatcher.search(query, in: candidates, limit: limit, after: previous, scope: scope)
            }.value
            guard let self, generation == self.searchGeneration else { return }
            self.searchState = result.state
            self.searchStateVersion = version
            self.matchCount = result.matchCount
            self.show(result.top.map { (items[$0.index], $0.match) })
        }
    }

    private func show(_ rows: [(item: FileIndexer.Item, match: FuzzyMatcher.Match)]) {
        // Batches arriving mid-search shouldn't yank the selection away from the row the user moved to.
        let selectedPath = userMovedSelection ? selectedItem?.relativePath : nil
        results = rows
        table.reloadData()
        let row = selectedPath.flatMap { path in results.firstIndex { $0.item.relativePath == path } } ?? 0
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updateStatus()
    }

    private func updateStatus() {
        let count = scopeCount.formatted()
        let hasQuery = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        if index.isWalking {
            status.stringValue = index.hasWalked ? "Updating… \(count) items" : "Searching… \(count) items"
        } else if hasQuery {
            status.stringValue = matchCount == 0 ? "No matches in \(count) items"
                : "\(matchCount.formatted()) \(matchCount == 1 ? "match" : "matches") in \(count) items"
        } else {
            status.stringValue = "\(count) items"
        }
        if !index.isWalking, index.reachedLimit { status.stringValue += " (stopped at the limit)" }
    }

    // MARK: Choosing

    private var selectedItem: FileIndexer.Item? {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { return nil }
        return results[row].item
    }

    private func choose(open: Bool) {
        guard let item = selectedItem else { return }
        close()
        onChoose?(item.url(in: root), item.isBrowsable, open)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        choose(open: false)
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        userMovedSelection = true
        let row = max(0, min(results.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Layout

    private func buildPanel() {
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.onCommandReturn = { [weak self] in self?.choose(open: true) }

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        glass.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        let searched = folder.isEmpty ? root : root.appendingPathComponent(folder)
        field.placeholderString = "Find in \(searched.lastPathComponent.isEmpty ? searched.path : searched.lastPathComponent)"
        field.delegate = self
        field.cell?.isScrollable = true

        let separator = NSBox()
        separator.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor

        let hint = NSTextField(labelWithString: "↩ Show in Folder   ⌘↩ Open   ⎋ Close")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .tertiaryLabelColor

        for view in [glass, field, separator, scroll, status, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        panel.contentView = background

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            glass.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight * 10),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            status.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
            hint.firstBaselineAnchor.constraint(equalTo: status.firstBaselineAnchor),
            hint.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: status.trailingAnchor, constant: 12),
        ])
        panel.setContentSize(background.fittingSize)
    }

    private func icon(for item: FileIndexer.Item) -> NSImage {
        if item.isBrowsable { return folderIcon }
        // Packages (apps, bundles) have their own icons; plain files share one per extension.
        if item.isDirectory { return NSWorkspace.shared.icon(forFile: item.url(in: root).path) }
        let ext = (item.relativePath as NSString).pathExtension.lowercased()
        if let cached = iconsByExtension[ext] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        iconsByExtension[ext] = icon
        return icon
    }
}

extension FileFinderController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        userMovedSelection = false
        search()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): moveSelection(by: -10)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): moveSelection(by: 10)
        case #selector(NSResponder.insertNewline(_:)): choose(open: false)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }
}

extension FileFinderController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("FinderCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FinderCell ?? FinderCell(identifier: id)
        let (item, match) = results[row]
        // Shown relative to the searched folder, which may be below the index root.
        let path = (item.relativePath as NSString).substring(from: skip)
        cell.show(path: path, positions: match.positions.map { $0 - skip }, icon: icon(for: item))
        return cell
    }

    // The field keeps focus, so draw the selection as if the table had it.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        EmphasizedRowView()
    }
}

extension FileFinderController: NSWindowDelegate {
    // Clicking back into the window dismisses the finder, like Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// A borderless panel that can take key focus and reports Escape and Cmd+Return.
private final class FinderPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onCommandReturn: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.borderless],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

/// One result: icon, the name with matched letters in bold, and the folder it's in.
private final class FinderCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        name.lineBreakMode = .byTruncatingMiddle
        folder.lineBreakMode = .byTruncatingHead
        for view in [icon, name, folder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            folder.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            folder.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(path: String, positions: [Int], icon image: NSImage) {
        icon.image = image
        let text = path as NSString
        let slash = text.range(of: "/", options: .backwards)
        let nameStart = slash.location == NSNotFound ? 0 : slash.location + 1
        let nameText = text.substring(from: nameStart)
        let folderText = nameStart == 0 ? "" : text.substring(to: nameStart - 1)

        let size = NSFont.systemFontSize
        name.attributedStringValue = Self.highlighted(
            nameText, positions.filter { $0 >= nameStart }.map { $0 - nameStart },
            font: .systemFont(ofSize: size), bold: .boldSystemFont(ofSize: size),
            color: .labelColor, matchColor: .labelColor)
        let small = NSFont.smallSystemFontSize
        folder.attributedStringValue = Self.highlighted(
            folderText, positions.filter { $0 < nameStart - 1 },
            font: .systemFont(ofSize: small), bold: .boldSystemFont(ofSize: small),
            color: .secondaryLabelColor, matchColor: .labelColor)
    }

    private static func highlighted(
        _ text: String, _ positions: [Int], font: NSFont, bold: NSFont, color: NSColor, matchColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let length = result.length
        for position in positions where position < length {
            result.addAttributes([.font: bold, .foregroundColor: matchColor], range: NSRange(location: position, length: 1))
        }
        return result
    }
}
