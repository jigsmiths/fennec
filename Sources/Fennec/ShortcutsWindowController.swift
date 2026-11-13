import AppKit
import FennecCore

/// A panel listing every keyboard shortcut, grouped by menu. Built from the live main menu each time it opens,
/// so it always matches the real key equivalents.
@MainActor
final class ShortcutsWindowController: NSWindowController {
    static let shared = ShortcutsWindowController()

    /// Keys the folder views handle themselves, so no menu item lists them.
    private static let folderKeys: [(String, String)] = [
        ("Rename", ShortcutLabel.text(key: "\r", modifiers: [])),
        ("Quick Look", ShortcutLabel.text(key: " ", modifiers: [])),
        ("Copy instead of move", "⌥ while dragging"),
        ("Switch pane", ShortcutLabel.text(key: "\t", modifiers: [])),
        ("Even out the panes", "Double-click the divider"),
    ]

    private static let finderKeys: [(String, String)] = [
        ("Show in folder", ShortcutLabel.text(key: "\r", modifiers: [])),
        ("Open", ShortcutLabel.text(key: "\r", modifiers: [.command])),
        ("Close", ShortcutLabel.text(key: "\u{1B}", modifiers: [])),
    ]

    /// Items AppKit adds to the Edit menu on its own; they aren't Fennec's shortcuts.
    private static let systemActions: Set<Selector> = [
        Selector(("startDictation:")), #selector(NSApplication.orderFrontCharacterPalette(_:)),
    ]

    private let stack = NSStackView()

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
        panel.contentView = scroll

        NSLayoutConstraint.activate([
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
        rebuild()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (title, rows) in Self.groups() {
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
        groups.append(("In Find", finderKeys))
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

/// Escape closes the panel, like other macOS info panels.
private final class ShortcutsPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
