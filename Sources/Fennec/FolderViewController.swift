import AppKit
import FennecCore

@MainActor
protocol FolderContentView: NSViewController {
    var onOpen: (() -> Void)? { get set }
    var onRename: (() -> Void)? { get set }
    var onSelectionChange: (() -> Void)? { get set }
    var onQuickLook: (() -> Void)? { get set }
    var onFocus: (() -> Void)? { get set }
    var onSwitchPane: (() -> Void)? { get set }
    var dropHandler: FolderDropHandler? { get set }
    var onContextMenu: (() -> NSMenu?)? { get set }
    var selectedIndexes: IndexSet { get }
    func frame(ofItemAt index: Int) -> NSRect?
    func display(_ rows: [FileEntry], selecting: IndexSet, keepScroll: Bool)
    func focus()
    func handleKey(_ event: NSEvent)
    func beginRename(at index: Int, onEnd: @escaping (String?) -> Void)
}

@MainActor
protocol FolderDropHandler: AnyObject {
    func validateDrop(_ info: NSDraggingInfo, onto folder: FileEntry?) -> NSDragOperation
    func acceptDrop(_ info: NSDraggingInfo, onto folder: FileEntry?) -> Bool
}

extension NSScrollView {
    func keepingScrollPosition(_ update: () -> Void) {
        let origin = contentView.bounds.origin
        update()
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

@MainActor
final class FolderViewController: NSViewController {
    var onOpenFolder: ((URL) -> Void)?
    var onSelectionChange: (([FileEntry]) -> Void)?
    var onQuickLook: (() -> Void)?
    var onRename: ((URL, String) -> Void)?
    var onTransfer: (([URL], URL, TransferMode) -> Void)?
    var onFocus: (() -> Void)?
    var onSwitchPane: (() -> Void)?
    var onSettingsChange: (() -> Void)?

    var currentDirectory: URL? { directory }

    var showHidden = false {
        didSet { rearrange() }
    }

    private(set) var viewMode: ViewMode
    private(set) var sortOrder: FennecCore.SortOrder
    private var content: FolderContentView
    private let messageLabel = NSTextField(labelWithString: "")
    private var directory: URL?
    private var allEntries: [FileEntry] = []
    private var rows: [FileEntry] = []
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var pendingLoad: Int?
    private var pendingRenamePath: String?
    private var openRenames = 0
    private var reloadAfterRename = false
    private var watchers: [DirectoryWatcher] = []
    private var statsRefreshScheduled = false

    init(viewMode: ViewMode, sortOrder: FennecCore.SortOrder, showHidden: Bool) {
        self.viewMode = viewMode
        self.sortOrder = sortOrder
        self.showHidden = showHidden
        content = Self.makeContent(viewMode)
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(folderStatsDidUpdate(_:)), name: FolderStatsService.didUpdate, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var itemCount: Int { rows.count }

    var selectedEntries: [FileEntry] {
        content.selectedIndexes.filter { $0 < rows.count }.map { rows[$0] }
    }

    override func loadView() {
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        view = container
        attach(content)
    }

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        let selected = selectedPaths
        content.view.removeFromSuperview()
        content.removeFromParent()

        viewMode = mode
        WindowDefaults.viewMode = mode
        content = Self.makeContent(mode)
        attach(content)
        content.display(rows, selecting: indexes(of: selected), keepScroll: false)
        content.focus()
        onSettingsChange?()
    }

    private static func makeContent(_ mode: ViewMode) -> FolderContentView {
        switch mode {
        case .list: FileListViewController()
        case .grid: GridViewController()
        }
    }

    private func attach(_ child: FolderContentView) {
        if let list = child as? FileListViewController {
            list.sortOrder = sortOrder
            list.onSortChange = { [weak self] order in
                guard let self else { return }
                self.sortOrder = order
                WindowDefaults.sortOrder = order
                self.rearrange()
                self.onSettingsChange?()
            }
        }
        child.onOpen = { [weak self] in self?.openSelection() }
        child.onFocus = { [weak self] in self?.onFocus?() }
        child.onSwitchPane = { [weak self] in self?.onSwitchPane?() }
        child.onRename = { [weak self] in self?.renameSelection() }
        child.dropHandler = self
        child.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.onSelectionChange?(self.selectedEntries)
        }
        child.onQuickLook = { [weak self] in self?.onQuickLook?() }
        child.onContextMenu = { [weak self] in
            guard let self else { return nil }
            let inTrash = self.directory.map(FinderTrash.isTrash) ?? false
            return inTrash ? FolderContextMenu.makeForTrash(self.selectedEntries) : FolderContextMenu.make(for: self.selectedEntries)
        }

        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view, positioned: .below, relativeTo: messageLabel)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func forwardKey(_ event: NSEvent) {
        content.handleKey(event)
    }

    func focus() {
        content.focus()
    }

    func shareAnchor() -> (NSView, NSRect) {
        let rect = content.selectedIndexes.first.flatMap(content.frame(ofItemAt:))
        return (content.view, rect ?? content.view.bounds)
    }

    func show(_ url: URL, selecting selection: URL?, takeFocus: Bool = true) {
        loadViewIfNeeded()
        directory = url
        // The Trash view also lists iCloud Drive's trash, which is a separate folder.
        let watched = FinderTrash.isTrash(url)
            ? [url, Places.iCloudDrive.deletingLastPathComponent().appendingPathComponent(".Trash")] : [url]
        watchers = watched.map { DirectoryWatcher(url: $0) { [weak self] in self?.folderChanged() } }
        load(url, selecting: selection.map { [$0.standardizedFileURL.path] } ?? [], keepScroll: false)
        if takeFocus { content.focus() }
    }

    private func reload() {
        guard let directory else { return }
        load(directory, selecting: selectedPaths, keepScroll: true)
    }

    func reload(selecting urls: [URL], thenRename: Bool = false) {
        guard let directory else { return }
        if thenRename { pendingRenamePath = urls.first?.standardizedFileURL.path }
        load(directory, selecting: urls.map { $0.standardizedFileURL.path }, keepScroll: true)
    }

    private func load(_ url: URL, selecting paths: [String], keepScroll: Bool) {
        loadTask?.cancel()
        let started = ContinuousClock.now
        let showHidden = showHidden
        let order = sortOrder
        loadGeneration += 1
        let generation = loadGeneration
        pendingLoad = generation
        if !keepScroll { showLoadingIfSlow(generation) }

        loadTask = Task { [weak self] in
            let result: Result<([FileEntry], [FileEntry]), Error>
            do {
                let entries = try await BlockingIO.run { try DirectoryLoader.loadSync(url) }
                let stats = Self.hasFolderStats(url) ? await FolderStatsService.shared.childStats(of: url) : [:]
                result = .success(try await BlockingIO.run {
                    let measured = stats.isEmpty ? entries : FolderStats.apply(stats, to: entries)
                    return (measured, Sorting.arrange(measured, showHidden: showHidden, order: order))
                })
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled, self.loadGeneration == generation else { return }
            self.pendingLoad = nil
            let loaded = ContinuousClock.now

            switch result {
            case .success(let (entries, arranged)):
                self.allEntries = entries
                self.apply(arranged, selecting: paths, keepScroll: keepScroll)
                self.requestMissingStats()
            case .failure(let error):
                self.allEntries = []
                self.apply([], selecting: [], keepScroll: false)
                if FinderTrash.needsFullDiskAccess(error, opening: url) {
                    self.showMessage("Can't open folders in the Trash without Full Disk Access.\n"
                        + "Allow Fennec in System Settings › Privacy & Security › Full Disk Access, "
                        + "or Put Back or Move the folder out first.")
                } else {
                    self.showMessage("Can't open this folder.\n\(error.localizedDescription)")
                }
            }

            if Bench.enabled {
                self.view.window?.displayIfNeeded()
                if Bench.recordedColdLoad {
                    Bench.report(entries: self.allEntries.count, load: loaded - started, paint: .now - loaded)
                } else {
                    Bench.recordedColdLoad = true
                    try? await Task.sleep(for: .seconds(1))
                    self.reload()
                }
            }
        }
    }

    private func showLoadingIfSlow(_ generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.pendingLoad == generation else { return }
            self.rows = []
            self.content.display([], selecting: IndexSet(), keepScroll: false)
            self.onSelectionChange?([])
            self.showMessage("Loading…")
        }
    }

    private func rearrange() {
        apply(Sorting.arrange(allEntries, showHidden: showHidden, order: sortOrder),
              selecting: selectedPaths, keepScroll: true)
    }

    private func apply(_ newRows: [FileEntry], selecting paths: [String], keepScroll: Bool) {
        rows = newRows
        content.display(rows, selecting: indexes(of: paths), keepScroll: keepScroll)
        onSelectionChange?(selectedEntries)

        if rows.isEmpty {
            showMessage(allEntries.isEmpty ? "This folder is empty." : "Only hidden files here.")
        } else {
            messageLabel.isHidden = true
        }

        if let path = pendingRenamePath, rows.contains(where: { $0.path == path }) {
            pendingRenamePath = nil
            DispatchQueue.main.async { [weak self] in self?.renameSelection() }
        }
    }

    private func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
    }

    private static func hasFolderStats(_ url: URL) -> Bool {
        !FinderTrash.isTrash(url) && !Bench.enabled
    }

    private func requestMissingStats() {
        guard let directory, Self.hasFolderStats(directory) else { return }
        FolderStatsService.shared.request(rows.filter { $0.isDirectory && $0.folderStats == nil }.map(\.url))
    }

    @objc private func folderStatsDidUpdate(_ notification: Notification) {
        guard let walked = (notification.object as? URL)?.standardizedFileURL.path,
              let shown = directory?.standardizedFileURL.path else { return }
        let isAbove = walked == "/" || shown == walked || shown.hasPrefix(walked + "/")
        let isChild = (walked as NSString).deletingLastPathComponent == shown
        guard isAbove || isChild, !statsRefreshScheduled else { return }

        statsRefreshScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.statsRefreshScheduled = false
            guard let directory = self.directory else { return }
            let stats = await FolderStatsService.shared.childStats(of: directory)
            guard self.directory == directory, self.pendingLoad == nil else { return }
            if self.openRenames > 0 {
                self.reloadAfterRename = true
                return
            }
            self.allEntries = FolderStats.apply(stats, to: self.allEntries)
            self.rearrange()
        }
    }

    private var selectedPaths: [String] {
        selectedEntries.map(\.path)
    }

    private func indexes(of paths: [String]) -> IndexSet {
        let wanted = Set(paths)
        return wanted.isEmpty ? IndexSet() : IndexSet(rows.indices.filter { wanted.contains(rows[$0].path) })
    }

    func openSelection() {
        let entries = selectedEntries
        if entries.count == 1, let only = entries.first, only.isBrowsable {
            onOpenFolder?(only.url)
            return
        }
        for entry in entries where !entry.isBrowsable {
            NSWorkspace.shared.open(entry.url)
        }
    }

    func renameSelection() {
        let entries = selectedEntries
        guard entries.count == 1, let entry = entries.first,
              let index = rows.firstIndex(where: { $0.path == entry.path }) else { return }
        openRenames += 1
        content.beginRename(at: index) { [weak self] newName in
            guard let self else { return }
            openRenames -= 1
            if let newName { onRename?(entry.url, newName) }
            if openRenames == 0, reloadAfterRename {
                reloadAfterRename = false
                reload()
            }
        }
    }

    private func folderChanged() {
        if openRenames > 0 {
            reloadAfterRename = true
        } else {
            reload()
        }
    }
}

extension FolderViewController: FolderDropHandler {
    func validateDrop(_ info: NSDraggingInfo, onto folder: FileEntry?) -> NSDragOperation {
        guard let (_, _, mode) = drop(info, onto: folder) else { return [] }
        return mode == .copy ? .copy : .move
    }

    func acceptDrop(_ info: NSDraggingInfo, onto folder: FileEntry?) -> Bool {
        guard let (urls, target, mode) = drop(info, onto: folder) else { return false }
        onTransfer?(urls, target, mode)
        return true
    }

    private func drop(_ info: NSDraggingInfo, onto folder: FileEntry?) -> ([URL], URL, TransferMode)? {
        guard let target = folder?.url ?? directory else { return nil }
        let urls = FileClipboard.fileURLs(from: info.draggingPasteboard)
        guard let first = urls.first else { return nil }

        let targetPath = target.standardizedFileURL.path
        if urls.contains(where: { targetPath == $0.standardizedFileURL.path
            || targetPath.hasPrefix($0.standardizedFileURL.path + "/") }) {
            return nil
        }
        let flags = NSEvent.modifierFlags
        let mode = DropRules.mode(
            sameVolume: DropRules.isSameVolume(first, target),
            option: flags.contains(.option), command: flags.contains(.command))
        let alreadyThere = urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == targetPath }
        if mode == .move, alreadyThere { return nil }
        return (urls, target, mode)
    }
}
