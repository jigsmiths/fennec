import AppKit
import FennecCore

/// A Get Info panel for one item: kind, size, location, dates, owner and permissions.
/// One panel per item, like Finder; asking again for the same item brings its panel forward.
@MainActor
final class InfoWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: InfoWindowController] = [:]

    /// Opens panels for up to 10 items, cascading them so they don't stack exactly.
    static func show(_ entries: [FileEntry]) {
        var previous: NSWindow?
        for entry in entries.prefix(10) {
            let controller = open[entry.path] ?? InfoWindowController(entry: entry)
            open[entry.path] = controller
            if let previous, controller.window?.isVisible == false {
                controller.window?.setFrameTopLeftPoint(
                    NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
            }
            controller.showWindow(nil)
            previous = controller.window
        }
    }

    private let entry: FileEntry
    private let sizeLabel = InfoWindowController.value("")
    private var sizeTask: Task<Void, Never>?

    private init(entry: FileEntry) {
        self.entry = entry
        let panel = InfoPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "\(entry.name) Info"
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = makeContent()
        panel.center()
        loadSize()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        sizeTask?.cancel()
        Self.open[entry.path] = nil
    }

    private func makeContent() -> NSView {
        let info = FileInfo.load(entry.url)

        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: entry.path))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let name = Self.value(entry.name)
        name.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        name.maximumNumberOfLines = 3
        let header = NSStackView(views: [icon, name])
        header.spacing = 10

        let date = { (date: Date?) in date.map { $0.formatted(date: .long, time: .shortened) } ?? "--" }
        var rows: [(String, NSView)] = [
            ("Kind", Self.value(FileDisplay.kind(for: entry))),
            ("Size", sizeLabel),
            ("Where", Self.value(FileInfoFormatting.location(of: entry.url))),
            ("Created", Self.value(date(info.created))),
            ("Modified", Self.value(date(info.modified))),
        ]
        if entry.cloudStatus == .notDownloaded { rows.append(("iCloud", Self.value("Not downloaded"))) }
        if let owner = info.owner {
            rows.append(("Owner", Self.value([owner, info.group].compactMap { $0 }.joined(separator: " : "))))
        }
        if let permissions = info.permissions {
            let label = Self.value(FileInfoFormatting.permissions(permissions))
            label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            rows.append(("Permissions", label))
        }

        let grid = NSGridView(views: rows.map { title, value in
            let label = NSTextField(labelWithString: "\(title):")
            label.textColor = .secondaryLabelColor
            return [label, value]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let copyPath = NSButton(title: "Copy Path", target: self, action: #selector(copyPath(_:)))
        let copyFolder = NSButton(
            title: "Copy Enclosing Folder Path", target: self, action: #selector(copyEnclosingFolderPath(_:)))
        let buttons = NSStackView(views: [copyPath, copyFolder])
        buttons.spacing = 8

        let stack = NSStackView(views: [header, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        stack.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return stack
    }

    @objc private func copyPath(_ sender: Any?) {
        FileClipboard.writePaths([entry.url])
    }

    @objc private func copyEnclosingFolderPath(_ sender: Any?) {
        FileClipboard.writePaths(FileInfoFormatting.enclosingFolders(of: [entry.url]))
    }

    private func loadSize() {
        guard entry.isDirectory else {
            sizeLabel.stringValue = entry.size.map(FileInfoFormatting.size) ?? "--"
            return
        }
        sizeLabel.stringValue = "Calculating…"
        let url = entry.url
        sizeTask = Task { [weak self] in
            let cancelled = CancelFlag()
            let totals = await withTaskCancellationHandler {
                try? await BlockingIO.run { FileInfo.folderTotals(url, isCancelled: cancelled.get) }
            } onCancel: {
                cancelled.set()
            }
            guard let self, !Task.isCancelled, let totals = totals.flatMap({ $0 }) else { return }
            self.sizeLabel.stringValue = FileInfoFormatting.folderSize(bytes: totals.bytes, items: totals.items)
        }
    }

    private static func value(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = true
        field.preferredMaxLayoutWidth = 240
        return field
    }
}

/// Lets a cancelled panel stop the folder walk running on the blocking IO queue.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func set() { lock.withLock { cancelled = true } }
    @Sendable func get() -> Bool { lock.withLock { cancelled } }
}

/// Escape and Cmd+W close the panel.
private final class InfoPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
