import AppKit
import FennecCore

/// A panel listing every keyboard shortcut, grouped by menu. Built from the live main menu each time it opens,
/// so it always matches the real key equivalents.
@MainActor
final class ShortcutsWindowController: NSWindowController, NSSearchFieldDelegate {
    static let shared = ShortcutsWindowController()

    /// Keys the folder views handle themselves, so no menu item lists them.
    private static let folderKeys: [(String, String)] = [
        ("Rename", ShortcutLabel.text(key: "\r", modifiers: [])),
        ("Quick Look", ShortcutLabel.text(key: " ", modifiers: [])),
        ("Copy instead of move", "⌥ while dragging"),
        ("Switch pane", ShortcutLabel.text(key: "\t", modifiers: [])),
        ("Even out the panes", "Double-click the divider"),
    ]

    /// Items AppKit adds to the Edit menu on its own; they aren't Fennec's shortcuts.
    private static let systemActions: Set<Selector> = [
        Selector(("startDictation:")), #selector(NSApplication.orderFrontCharacterPalette(_:)),
    ]

    private let stack = NSStackView()
    private let searchField = NSSearchField()
    private var groups: [(String, [(String, String)])] = []

    private init() {
        let panel = ShortcutsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "Keyboard Shortcuts"
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 240)
        super.init(window: panel)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search by name or keys"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(searchField)
        content.addSubview(scroll)
        panel.contentView = content
        panel.initialFirstResponder = searchField
        panel.onCancel = { [weak self] in self?.cancel() }

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        groups = Self.groups()
        searchField.stringValue = ""
        rebuild()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ obj: Notification) {
        rebuild()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancel()
        return true
    }

    /// Esc clears the search first, then closes the panel.
    private func cancel() {
        if searchField.stringValue.isEmpty {
            close()
        } else {
            searchField.stringValue = ""
            rebuild()
        }
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let query = searchField.stringValue
        let filtered = groups.compactMap { title, rows -> (String, [(String, String)])? in
            let matching = rows.filter { ShortcutSearch.matches(query: query, name: $0.0, keys: $0.1) }
            return matching.isEmpty ? nil : (title, matching)
        }
        if filtered.isEmpty {
            let empty = NSTextField(labelWithString: "No matching shortcuts")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
        }
        for (title, rows) in filtered {
            let header = NSTextField(labelWithString: title)
            header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            if !stack.arrangedSubviews.isEmpty { stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!) }
            stack.addArrangedSubview(header)

            let grid = NSGridView(views: rows.map { name, keys in
                let keysLabel = NSTextField(labelWithString: keys)
                keysLabel.textColor = .secondaryLabelColor
                return [NSTextField(labelWithString: name), keysLabel]
            })
            grid.rowSpacing = 4
            grid.column(at: 1).xPlacement = .trailing
            stack.addArrangedSubview(grid)
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
    }

    private static func groups() -> [(String, [(String, String)])] {
        var groups: [(String, [(String, String)])] = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            var rows: [(String, String)] = []
            for item in menu.items where !item.isSeparatorItem && !item.keyEquivalent.isEmpty {
                if let action = item.action, systemActions.contains(action) { continue }
                let keys = ShortcutLabel.text(key: item.keyEquivalent, modifiers: modifiers(item.keyEquivalentModifierMask))
                // A hidden second key for the same command (Cmd+Down for Open) shares its row.
                if let index = rows.firstIndex(where: { $0.0 == item.title }) {
                    rows[index].1 += " or \(keys)"
                } else {
                    rows.append((item.title, keys))
                }
            }
            if !rows.isEmpty { groups.append((menu.title, rows)) }
        }
        groups.append(("In the File List", folderKeys))
        return groups
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Set<ShortcutLabel.Modifier> {
        var result: Set<ShortcutLabel.Modifier> = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}

/// Escape closes the panel, like other macOS info panels, unless `onCancel` handles it first.
private final class ShortcutsPanel: NSPanel {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { close() }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
