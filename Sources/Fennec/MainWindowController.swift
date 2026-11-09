import AppKit
import FennecCore
import Quartz

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    var onClose: (() -> Void)?

    private var history: NavigationHistory
    private let sidebar = SidebarViewController()
    private let folder = FolderViewController()
    private let preview = PreviewViewController()
    private let pathBar = PathBarView()
    private let splitController = NSSplitViewController()
    private var previewItem: NSSplitViewItem!
    private var backItem: NSToolbarItem?
    private var forwardItem: NSToolbarItem?
    private var viewModeItem: NSToolbarItemGroup?
    private var operations: OperationsController!
    private let operationsStatus = OperationsStatusView()
    private var operationsItem: NSToolbarItem?

    private static let backID = NSToolbarItem.Identifier("back")
    private static let forwardID = NSToolbarItem.Identifier("forward")
    private static let pathID = NSToolbarItem.Identifier("path")
    private static let viewModeID = NSToolbarItem.Identifier("viewMode")
    private static let previewToggleID = NSToolbarItem.Identifier("previewToggle")
    private static let operationsID = NSToolbarItem.Identifier("operations")
    private static let previewVisibleKey = "previewVisible"
    private static let previewWidthSetKey = "previewWidthSet"

    init(start: URL) {
        history = NavigationHistory(start: start)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        operations = OperationsController(window: window)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 320
        previewItem = NSSplitViewItem(inspectorWithViewController: preview)
        previewItem.minimumThickness = 220
        previewItem.maximumThickness = 520
        previewItem.isCollapsed = !UserDefaults.standard.bool(forKey: Self.previewVisibleKey)
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(NSSplitViewItem(viewController: folder))
        splitController.addSplitViewItem(previewItem)
        splitController.splitView.identifier = NSUserInterfaceItemIdentifier("FennecSplit")
        splitController.splitView.autosaveName = "FennecSplit"

        window.delegate = self
        window.contentViewController = splitController
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1200, height: 720))
        window.minSize = NSSize(width: 600, height: 360)
        window.center()
        window.setFrameAutosaveName("FennecMainWindow")

        let toolbar = NSToolbar(identifier: "FennecToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        sidebar.onNavigate = { [weak self] url in self?.navigate(to: url) }
        pathBar.onNavigate = { [weak self] url in self?.navigate(to: url) }
        folder.onOpenFolder = { [weak self] url in self?.navigate(to: url) }
        folder.onSelectionChange = { [weak self] entries in self?.selectionChanged(entries) }
        folder.onQuickLook = { [weak self] in self?.toggleQuickLook(nil) }
        folder.onRename = { [weak self] url, name in self?.rename(url, to: name) }
        folder.onTransfer = { [weak self] urls, destination, mode in
            self?.operations.transfer(urls, to: destination, mode: mode)
        }
        operations.onJobsChanged = { [weak self] in self?.updateOperationsItem() }
        operations.onPlaced = { [weak self] urls in self?.folder.reload(selecting: urls) }

        show(history.current, selecting: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // The split view restores its saved divider positions when the window appears, so set the default after that.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        applyDefaultPreviewWidth()
    }

    // MARK: Navigation

    func navigate(to url: URL, selecting selection: URL? = nil) {
        history.visit(url)
        show(history.current, selecting: selection)
    }

    private func show(_ url: URL, selecting selection: URL?) {
        folder.show(url, selecting: selection)
        pathBar.show(url)
        sidebar.highlight(url)
        window?.title = PathBarView.segments(for: url).last?.name ?? url.lastPathComponent
        backItem?.isEnabled = history.canGoBack
        forwardItem?.isEnabled = history.canGoForward
    }

    @objc func goBack(_ sender: Any?) {
        if let url = history.goBack() { show(url, selecting: nil) }
    }

    @objc func goForward(_ sender: Any?) {
        if let url = history.goForward() { show(url, selecting: nil) }
    }

    @objc func goUp(_ sender: Any?) {
        guard history.canGoUp else { return }
        let current = history.current
        navigate(to: current.deletingLastPathComponent(), selecting: current)
    }

    @objc func goToPlace(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { navigate(to: url) }
    }

    @objc func openSelection(_ sender: Any?) {
        folder.openSelection()
    }

    // MARK: View

    @objc func toggleHiddenFiles(_ sender: Any?) {
        folder.showHidden.toggle()
    }

    @objc func showAsList(_ sender: Any?) {
        setViewMode(.list)
    }

    @objc func showAsGrid(_ sender: Any?) {
        setViewMode(.grid)
    }

    @objc private func viewModeChanged(_ sender: NSToolbarItemGroup) {
        setViewMode(sender.selectedIndex == 1 ? .grid : .list)
    }

    private func setViewMode(_ mode: ViewMode) {
        folder.setViewMode(mode)
        viewModeItem?.selectedIndex = mode == .grid ? 1 : 0
    }

    @objc func togglePreview(_ sender: Any?) {
        let show = previewItem.isCollapsed
        UserDefaults.standard.set(show, forKey: Self.previewVisibleKey)
        if show, !UserDefaults.standard.bool(forKey: Self.previewWidthSetKey) {
            // Not animated: the divider can't be positioned while the pane is still sliding in.
            previewItem.isCollapsed = false
            applyDefaultPreviewWidth()
        } else {
            previewItem.animator().isCollapsed = !show
        }
        if show { preview.show(folder.selectedEntries, includeHidden: folder.showHidden) }
    }

    /// Opens the pane at 300pt the first time; after that the split view's autosave keeps the user's width.
    private func applyDefaultPreviewWidth() {
        guard !previewItem.isCollapsed, !UserDefaults.standard.bool(forKey: Self.previewWidthSetKey) else { return }
        let splitView = splitController.splitView
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(splitView.bounds.width - 300 - splitView.dividerThickness, ofDividerAt: 1)
        UserDefaults.standard.set(true, forKey: Self.previewWidthSetKey)
    }

    private func selectionChanged(_ entries: [FileEntry]) {
        if !previewItem.isCollapsed { preview.show(entries, includeHidden: folder.showHidden) }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    // MARK: Quick Look panel

    @objc func toggleQuickLook(_ sender: Any?) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else if !folder.selectedEntries.isEmpty {
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    // AppKit declares these hooks without actor isolation but calls them on the main thread.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    // MARK: File operations

    private var selectedURLs: [URL] { folder.selectedEntries.map(\.url) }

    @objc func copy(_ sender: Any?) {
        FileClipboard.write(selectedURLs, cut: false)
    }

    @objc func cut(_ sender: Any?) {
        FileClipboard.write(selectedURLs, cut: true)
    }

    @objc func paste(_ sender: Any?) {
        let clipboard = FileClipboard.read()
        paste(clipboard.urls, mode: clipboard.isCut ? .move : .copy)
    }

    /// Cmd+Option+V: move what's on the clipboard here, like Finder.
    @objc func pasteAsMove(_ sender: Any?) {
        paste(FileClipboard.read().urls, mode: .move)
    }

    private func paste(_ urls: [URL], mode: TransferMode) {
        guard let destination = folder.currentDirectory, !urls.isEmpty else { return }
        operations.transfer(urls, to: destination, mode: mode)
        if mode == .move { FileClipboard.clear() }
    }

    @objc func moveToTrash(_ sender: Any?) {
        operations.trash(selectedURLs)
    }

    @objc func deleteImmediately(_ sender: Any?) {
        operations.deleteImmediately(selectedURLs)
    }

    @objc func renameSelection(_ sender: Any?) {
        folder.renameSelection()
    }

    @objc func newFolder(_ sender: Any?) {
        guard let directory = folder.currentDirectory else { return }
        Task {
            if let created = await operations.newFolder(in: directory) {
                folder.reload(selecting: [created], thenRename: true)
            }
        }
    }

    private func rename(_ url: URL, to name: String) {
        Task {
            // On failure, reloading puts the real name back over the rejected text.
            let renamed = await operations.rename(url, to: name)
            folder.reload(selecting: [renamed ?? url])
        }
    }

    private func updateOperationsItem() {
        operationsStatus.show(operations.visibleJobs)
        operationsItem?.isHidden = operations.visibleJobs.isEmpty
    }

    // MARK: Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return history.canGoBack
        case #selector(goForward(_:)): return history.canGoForward
        case #selector(goUp(_:)): return history.canGoUp
        case #selector(toggleQuickLook(_:)): return !folder.selectedEntries.isEmpty
        case #selector(copy(_:)), #selector(cut(_:)), #selector(moveToTrash(_:)), #selector(deleteImmediately(_:)):
            return !folder.selectedEntries.isEmpty
        case #selector(renameSelection(_:)): return folder.selectedEntries.count == 1
        case #selector(paste(_:)), #selector(pasteAsMove(_:)):
            return FileClipboard.hasFiles && folder.currentDirectory != nil
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = folder.showHidden ? .on : .off
        case #selector(showAsList(_:)):
            menuItem.state = folder.viewMode == .list ? .on : .off
        case #selector(showAsGrid(_:)):
            menuItem.state = folder.viewMode == .grid ? .on : .off
        case #selector(togglePreview(_:)):
            menuItem.title = previewItem.isCollapsed ? "Show Preview" : "Hide Preview"
        default: break
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.backID, Self.forwardID, Self.pathID,
         .flexibleSpace, Self.operationsID, Self.viewModeID, Self.previewToggleID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch id {
        case Self.backID:
            let item = button(id, "Back", "chevron.left", #selector(goBack(_:)))
            item.isEnabled = history.canGoBack
            backItem = item
            return item
        case Self.forwardID:
            let item = button(id, "Forward", "chevron.right", #selector(goForward(_:)))
            item.isEnabled = history.canGoForward
            forwardItem = item
            return item
        case Self.pathID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Path"
            item.view = pathBar
            item.visibilityPriority = .high
            pathBar.translatesAutoresizingMaskIntoConstraints = false
            // A width wider than the toolbar pushes this item and the buttons into the overflow menu.
            NSLayoutConstraint.activate([
                pathBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
                pathBar.widthAnchor.constraint(lessThanOrEqualToConstant: 900),
                pathBar.heightAnchor.constraint(equalToConstant: 28),
            ])
            return item
        case Self.viewModeID:
            let images = ["list.bullet", "square.grid.2x2"].compactMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            let group = NSToolbarItemGroup(
                itemIdentifier: id, images: images, selectionMode: .selectOne,
                labels: ["List", "Grid"], target: self, action: #selector(viewModeChanged(_:)))
            group.label = "View"
            group.selectedIndex = folder.viewMode == .grid ? 1 : 0
            viewModeItem = group
            return group
        case Self.previewToggleID:
            return button(id, "Preview", "sidebar.right", #selector(togglePreview(_:)))
        case Self.operationsID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Operations"
            item.view = operationsStatus
            item.isHidden = operations.visibleJobs.isEmpty
            operationsItem = item
            return item
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.autovalidates = false
        item.target = self
        item.action = action
        return item
    }
}

extension MainWindowController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        folder.selectedEntries.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let entries = folder.selectedEntries
        return index < entries.count ? entries[index].url as NSURL : nil
    }

    // Arrow keys in the panel move the selection in the folder, like Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        folder.forwardKey(event)
        return true
    }
}
