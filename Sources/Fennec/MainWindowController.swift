import AppKit
import FennecCore
import Quartz

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    var onClose: (() -> Void)?
    /// Something the session file records changed.
    var onStateChange: (() -> Void)?

    private let sidebar = SidebarViewController()
    private let panes: PanesViewController
    private let preview = PreviewViewController()
    private let splitController = NSSplitViewController()
    private var previewItem: NSSplitViewItem!
    private var viewModeItem: NSToolbarItemGroup?
    private var operations: OperationsController!
    private let operationsStatus = OperationsStatusView()
    private var operationsItem: NSToolbarItem?
    private var finder: FileFinderController?
    private var finderIndex: FinderIndex?
    /// The app-wide index of home, if there is one.
    var sharedFinderIndex: FinderIndex?

    private static let viewModeID = NSToolbarItem.Identifier("viewMode")
    private static let previewToggleID = NSToolbarItem.Identifier("previewToggle")
    private static let splitToggleID = NSToolbarItem.Identifier("splitToggle")
    private static let operationsID = NSToolbarItem.Identifier("operations")
    private static let previewWidthSetKey = "previewWidthSet"

    /// The active pane's folder view. Commands, the preview and Quick Look act on it.
    private var folder: FolderViewController { panes.active.folder }

    /// The folder the active pane shows.
    var activeFolder: URL { panes.active.currentFolder }

    var windowState: WindowState {
        panes.state(frame: window?.frame, previewVisible: !previewItem.isCollapsed)
    }

    init(state: WindowState) {
        panes = PanesViewController(state: state)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        operations = OperationsController(window: window)
        panes.configurePane = { [weak self] pane in self?.configure(pane) }
        panes.onActivePaneChange = { [weak self] in self?.activePaneChanged() }
        panes.onStateChange = { [weak self] in self?.stateChanged() }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 320
        previewItem = NSSplitViewItem(inspectorWithViewController: preview)
        previewItem.minimumThickness = 220
        previewItem.maximumThickness = 520
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(NSSplitViewItem(viewController: panes))
        splitController.addSplitViewItem(previewItem)
        // Sidebar and preview widths are shared by all windows; each window's pane divider is in the session.
        splitController.splitView.identifier = NSUserInterfaceItemIdentifier("FennecSplit")
        splitController.splitView.autosaveName = "FennecSplit"
        // After the preview exists: loading a pane's folder updates the preview.
        panes.start()

        window.delegate = self
        window.contentViewController = splitController
        // Only once the split is in the window: that restores the autosaved (shared) collapsed state, but each
        // window keeps its own preview setting.
        previewItem.isCollapsed = !state.previewVisible
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1200, height: 720))
        updateMinimumSize(split: state.panes.count == 2)
        place(window, frame: state.frame)

        let toolbar = NSToolbar(identifier: "FennecToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        sidebar.onNavigate = { [weak self] url in self?.panes.active.navigate(to: url) }
        operations.onJobsChanged = { [weak self] in self?.updateOperationsItem() }
        operations.onPlaced = { [weak self] urls in self?.reloadPanes(showing: urls) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // The split view restores its saved divider positions when the window appears, so set the default after that.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        applyDefaultPreviewWidth()
        activePaneChanged()
    }

    /// Restores a saved frame if it's still on a screen; otherwise cascades from the frontmost window.
    private func place(_ window: NSWindow, frame: CGRect?) {
        if let frame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: false)
        } else if let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 24, y: key.frame.maxY - 24))
        } else {
            window.center()
        }
    }

    private func updateMinimumSize(split: Bool) {
        window?.minSize = NSSize(width: split ? 780 : 600, height: 360)
    }

    private func stateChanged() {
        updateMinimumSize(split: panes.isSplit)
        onStateChange?()
    }

    // MARK: Panes

    private func configure(_ pane: PaneController) {
        let folder = pane.folder
        folder.onOpenFolder = { [weak pane] url in pane?.navigate(to: url) }
        folder.onSelectionChange = { [weak self, weak pane] entries in
            guard let self, pane === self.panes.active else { return }
            self.selectionChanged(entries)
        }
        folder.onQuickLook = { [weak self] in self?.toggleQuickLook(nil) }
        folder.onRename = { [weak self, weak pane] url, name in
            guard let pane else { return }
            self?.rename(url, to: name, in: pane)
        }
        folder.onTransfer = { [weak self] urls, destination, mode in
            self?.operations.transfer(urls, to: destination, mode: mode)
        }
        pane.onNavigate = { [weak self, weak pane] in
            guard let self else { return }
            if pane === self.panes.active { self.activePaneChanged() }
            self.stateChanged()
        }
    }

    /// Points the sidebar, title, view mode switch and preview at the active pane.
    private func activePaneChanged() {
        let url = activeFolder
        sidebar.highlight(url)
        window?.title = PathBarView.segments(for: url).last?.name ?? url.lastPathComponent
        viewModeItem?.selectedIndex = folder.viewMode == .grid ? 1 : 0
        selectionChanged(folder.selectedEntries)
    }

    /// Selects newly placed items in every pane showing the folder they landed in.
    private func reloadPanes(showing urls: [URL]) {
        for pane in panes.panes {
            let path = pane.currentFolder.standardizedFileURL.path
            let here = urls.filter { $0.deletingLastPathComponent().standardizedFileURL.path == path }
            if !here.isEmpty { pane.folder.reload(selecting: here) }
        }
    }

    @objc func toggleSplit(_ sender: Any?) {
        panes.toggleSplit()
    }

    /// Shows the selected folder, or this pane's folder, in the other pane.
    @objc func openInOtherPane(_ sender: Any?) {
        let selected = folder.selectedEntries
        let target = selected.count == 1 && selected[0].isBrowsable ? selected[0].url : activeFolder
        if let other = panes.other {
            other.navigate(to: target)
        } else {
            panes.openSplit(at: target)
        }
    }

    @objc func copyToOtherPane(_ sender: Any?) {
        transferToOtherPane(.copy)
    }

    @objc func moveToOtherPane(_ sender: Any?) {
        transferToOtherPane(.move)
    }

    private func transferToOtherPane(_ mode: TransferMode) {
        guard let other = panes.other, !selectedURLs.isEmpty else { return }
        operations.transfer(selectedURLs, to: other.currentFolder, mode: mode)
    }

    // MARK: Navigation

    @objc func goBack(_ sender: Any?) {
        panes.active.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        panes.active.goForward()
    }

    @objc func goUp(_ sender: Any?) {
        panes.active.goUp()
    }

    @objc func goToPlace(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { panes.active.navigate(to: url) }
    }

    @objc func openSelection(_ sender: Any?) {
        folder.openSelection()
    }

    /// Fuzzy-finds everything under the active pane's folder.
    @objc func findFiles(_ sender: Any?) {
        guard let window else { return }
        finder?.close()
        let pane = panes.active
        let folder = pane.currentFolder, includeHidden = panes.showsHidden
        // The app's home index covers most searches; anything else gets this window's own index, kept for
        // the last folder searched so searching it (or inside it) again is instant.
        let index: FinderIndex
        let relativePath: String
        if let shared = sharedFinderIndex, let path = shared.relativePath(of: folder, includeHidden: includeHidden) {
            (index, relativePath) = (shared, path)
        } else if let cached = finderIndex, let path = cached.relativePath(of: folder, includeHidden: includeHidden) {
            (index, relativePath) = (cached, path)
        } else {
            index = FinderIndex(root: folder, includeHidden: includeHidden)
            finderIndex = index
            relativePath = ""
        }
        let finder = FileFinderController(index: index, folder: relativePath)
        finder.onChoose = { [weak pane] url, isBrowsable, open in
            guard let pane else { return }
            if !open {
                pane.navigate(to: url.deletingLastPathComponent(), selecting: url)
            } else if isBrowsable {
                pane.navigate(to: url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        finder.show(over: window)
        self.finder = finder
    }

    // MARK: View

    @objc func toggleHiddenFiles(_ sender: Any?) {
        panes.setShowHidden(!panes.showsHidden)
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
        WindowDefaults.previewVisible = show
        if show, !UserDefaults.standard.bool(forKey: Self.previewWidthSetKey) {
            // Not animated: the divider can't be positioned while the pane is still sliding in.
            previewItem.isCollapsed = false
            applyDefaultPreviewWidth()
        } else {
            previewItem.animator().isCollapsed = !show
        }
        if show { preview.show(folder.selectedEntries, includeHidden: panes.showsHidden) }
        onStateChange?()
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
        if !previewItem.isCollapsed { preview.show(entries, includeHidden: panes.showsHidden) }
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

    @objc func openWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL, !selectedURLs.isEmpty else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The selection, or the folder being shown when nothing is selected, like Finder.
    private var selectedOrFolderURLs: [URL] {
        let selected = selectedURLs
        return selected.isEmpty ? folder.currentDirectory.map { [$0] } ?? [] : selected
    }

    @objc func getInfo(_ sender: Any?) {
        let entries = folder.selectedEntries
        InfoWindowController.show(entries.isEmpty
            ? folder.currentDirectory.map { [DirectoryLoader.entry(at: $0)] } ?? []
            : entries)
    }

    @objc func copyPath(_ sender: Any?) {
        FileClipboard.writePaths(selectedOrFolderURLs)
    }

    @objc func copyEnclosingFolderPath(_ sender: Any?) {
        FileClipboard.writePaths(FileInfoFormatting.enclosingFolders(of: selectedOrFolderURLs))
    }

    /// File > Share…, anchored on the first selected item.
    @objc func share(_ sender: Any?) {
        guard !selectedURLs.isEmpty else { return }
        let (view, rect) = folder.shareAnchor()
        NSSharingServicePicker(items: selectedURLs.map { $0 as NSURL }).show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    @objc func renameSelection(_ sender: Any?) {
        folder.renameSelection()
    }

    @objc func newFolder(_ sender: Any?) {
        let folder = folder
        guard let directory = folder.currentDirectory else { return }
        Task {
            if let created = await operations.newFolder(in: directory) {
                folder.reload(selecting: [created], thenRename: true)
            }
        }
    }

    private func rename(_ url: URL, to name: String, in pane: PaneController) {
        Task {
            // On failure, reloading puts the real name back over the rejected text.
            let renamed = await operations.rename(url, to: name)
            pane.folder.reload(selecting: [renamed ?? url])
        }
    }

    private func updateOperationsItem() {
        operationsStatus.show(operations.visibleJobs)
        operationsItem?.isHidden = operations.visibleJobs.isEmpty
    }

    // MARK: Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let history = panes.active.history
        switch menuItem.action {
        case #selector(goBack(_:)): return history.canGoBack
        case #selector(goForward(_:)): return history.canGoForward
        case #selector(goUp(_:)): return history.canGoUp
        case #selector(toggleQuickLook(_:)): return !folder.selectedEntries.isEmpty
        case #selector(copy(_:)), #selector(cut(_:)), #selector(moveToTrash(_:)), #selector(deleteImmediately(_:)),
             #selector(share(_:)), #selector(openWith(_:)):
            return !folder.selectedEntries.isEmpty
        case #selector(getInfo(_:)), #selector(copyPath(_:)), #selector(copyEnclosingFolderPath(_:)):
            return !selectedOrFolderURLs.isEmpty
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
            return panes.isSplit && !folder.selectedEntries.isEmpty
        case #selector(renameSelection(_:)): return folder.selectedEntries.count == 1
        case #selector(paste(_:)), #selector(pasteAsMove(_:)):
            return FileClipboard.hasFiles && folder.currentDirectory != nil
        case #selector(toggleSplit(_:)):
            menuItem.state = panes.isSplit ? .on : .off
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = panes.showsHidden ? .on : .off
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

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowDidMove(_ notification: Notification) {
        onStateChange?()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        onStateChange?()
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.operationsID, Self.viewModeID,
         Self.splitToggleID, Self.previewToggleID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch id {
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
        case Self.splitToggleID:
            return button(id, "Split Panes", "rectangle.split.2x1", #selector(toggleSplit(_:)))
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
