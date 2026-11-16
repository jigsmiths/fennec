import AppKit
import FennecCore

/// A floating path field over the window, like Finder's Go to Folder, suggesting folders as you type.
/// Tab completes the selected (or first) suggestion; Return goes to the selected one, or else the typed path.
@MainActor
final class GoToFolderController: NSObject {
    var onGo: ((PathEntry.Target) -> Void)?

    private static let suggestionLimit = 8
    private static let rowHeight: CGFloat = 28

    /// Relative paths are typed from here.
    private let base: URL
    private let includeHidden: Bool
    private let panel = FinderPanel()
    private let field = NSTextField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var tableHeight: NSLayoutConstraint!
    private var suggestions: [PathEntry.Suggestion] = []
    /// The last folder listed, so typing within one folder only re-filters.
    private var listing: (path: String, folders: [FileEntry])?
    private var generation = 0
    private var isClosed = false
    private let folderIcon = NSWorkspace.shared.icon(for: .folder)

    init(base: URL, includeHidden: Bool, text: String) {
        self.base = base
        self.includeHidden = includeHidden
        super.init()
        buildPanel()
        field.stringValue = text
    }

    func show(over parent: NSWindow) {
        let width = min(560, parent.frame.width - 40)
        let height = panel.frame.height
        panel.setFrame(NSRect(x: parent.frame.midX - width / 2, y: parent.frame.maxY - 90 - height,
                              width: width, height: height), display: false)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        updateSuggestions()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        generation += 1
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
    }

    // MARK: Suggestions

    private func updateSuggestions() {
        guard !isClosed else { return }
        generation += 1
        let current = generation
        let query = PathEntry.query(for: field.stringValue, relativeTo: base)
        let includeHidden = self.includeHidden
        let cached = listing?.path == query.folder.path ? listing?.folders : nil
        Task { [weak self] in
            // Listing runs off the main thread so a slow volume doesn't stall typing.
            let folders = if let cached { cached } else {
                await Task.detached(priority: .userInitiated) { PathEntry.folders(in: query.folder) }.value
            }
            guard let self, current == self.generation else { return }
            self.listing = (query.folder.path, folders)
            self.show(PathEntry.suggestions(query, in: folders, includeHidden: includeHidden,
                                            limit: Self.suggestionLimit))
        }
    }

    private func show(_ rows: [PathEntry.Suggestion]) {
        suggestions = rows
        table.reloadData()
        tableHeight.constant = Self.rowHeight * CGFloat(rows.count)
        // Grow or shrink downwards, keeping the field where it is.
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height),
                       display: true)
    }

    private var selectedSuggestion: PathEntry.Suggestion? {
        let row = table.selectedRow
        return row >= 0 && row < suggestions.count ? suggestions[row] : nil
    }

    private func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        // Moving up past the first row goes back to the typed path.
        let row = table.selectedRow + delta
        if row < 0 {
            table.deselectAll(nil)
            return
        }
        let clamped = min(suggestions.count - 1, row)
        table.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        table.scrollRowToVisible(clamped)
    }

    private func complete() {
        guard let suggestion = selectedSuggestion ?? suggestions.first else {
            NSSound.beep()
            return
        }
        field.stringValue = suggestion.completion
        field.currentEditor()?.selectedRange = NSRange(location: (suggestion.completion as NSString).length, length: 0)
        textChanged()
    }

    private func textChanged() {
        table.deselectAll(nil)
        showHint()
        updateSuggestions()
    }

    // MARK: Going

    private func go() {
        let target = selectedSuggestion.map { PathEntry.Target.folder($0.url) }
            ?? PathEntry.resolve(field.stringValue, relativeTo: base)
        if case .notFound = target {
            status.stringValue = "There's no folder or file at that path."
            status.textColor = .systemRed
            NSSound.beep()
            return
        }
        close()
        onGo?(target)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        if selectedSuggestion != nil { go() }
    }

    private func showHint() {
        status.stringValue = "⇥ Complete   ↩ Go   ⎋ Close"
        status.textColor = .tertiaryLabelColor
    }

    // MARK: Layout

    private func buildPanel() {
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let symbol = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
        symbol.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.placeholderString = "Go to Folder"
        field.delegate = self
        field.cell?.isScrollable = true

        let separator = NSBox()
        separator.boxType = .separator

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder")))
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
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byTruncatingTail
        showHint()

        for view in [symbol, field, separator, scroll, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        panel.contentView = background

        tableHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            symbol.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            tableHeight,
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
        ])
        panel.setContentSize(NSSize(width: 560, height: background.fittingSize.height))
    }
}

extension GoToFolderController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        textChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.insertTab(_:)): complete()
        case #selector(NSResponder.insertNewline(_:)): go()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }
}

extension GoToFolderController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        suggestions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SuggestionCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SuggestionCell
            ?? SuggestionCell(identifier: id)
        cell.show(suggestions[row], icon: folderIcon)
        return cell
    }

    // The field keeps focus, so draw the selection as if the table had it.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        EmphasizedRowView()
    }
}

extension GoToFolderController: NSWindowDelegate {
    // Clicking back into the window dismisses the panel, like Find.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// One suggestion: a folder icon and the name with the typed part in bold.
private final class SuggestionCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        name.lineBreakMode = .byTruncatingMiddle
        for view in [icon, name] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ suggestion: PathEntry.Suggestion, icon image: NSImage) {
        icon.image = image
        let size = NSFont.systemFontSize
        let text = NSMutableAttributedString(string: suggestion.name, attributes: [.font: NSFont.systemFont(ofSize: size)])
        if NSMaxRange(suggestion.matchRange) <= text.length {
            text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: suggestion.matchRange)
        }
        name.attributedStringValue = text
    }
}
