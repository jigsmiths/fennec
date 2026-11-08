import AppKit
import FennecCore

enum ViewMode: String {
    case list, grid
}

/// A view that shows a folder's rows. The list and the grid both implement it.
@MainActor
protocol FolderContentView: NSViewController {
    var onOpen: (() -> Void)? { get set }
    var onSelectionChange: (() -> Void)? { get set }
    var onQuickLook: (() -> Void)? { get set }
    var selectedIndexes: IndexSet { get }
    func display(_ rows: [FileEntry], selecting: IndexSet, keepScroll: Bool)
    func focus()
    /// Key events forwarded from the Quick Look panel, so arrow keys keep moving the selection.
    func handleKey(_ event: NSEvent)
}

/// Loads, watches, sorts and filters one folder, and shows it in the current view mode.
@MainActor
final class FolderViewController: NSViewController {
    var onOpenFolder: ((URL) -> Void)?
    var onSelectionChange: (([FileEntry]) -> Void)?
    var onQuickLook: (() -> Void)?

    var showHidden = false {
        didSet { rearrange() }
    }

    private(set) var viewMode: ViewMode
    private var sortOrder = FennecCore.SortOrder()
    private var content: FolderContentView
    private let messageLabel = NSTextField(labelWithString: "")
    private var directory: URL?
    private var allEntries: [FileEntry] = []
    private var rows: [FileEntry] = []
    private var loadTask: Task<Void, Never>?
    private var watcher: DirectoryWatcher?

    private static let viewModeKey = "viewMode"

    init() {
        viewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: Self.viewModeKey) ?? "") ?? .list
        content = Self.makeContent(viewMode)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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

    // MARK: View mode

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        let selected = selectedPaths
        content.view.removeFromSuperview()
        content.removeFromParent()

        viewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.viewModeKey)
        content = Self.makeContent(mode)
        attach(content)
        content.display(rows, selecting: indexes(of: selected), keepScroll: false)
        content.focus()
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
                self?.sortOrder = order
                self?.rearrange()
            }
        }
        child.onOpen = { [weak self] in self?.openSelection() }
        child.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.onSelectionChange?(self.selectedEntries)
        }
        child.onQuickLook = { [weak self] in self?.onQuickLook?() }

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

    // MARK: Loading

    func show(_ url: URL, selecting selection: URL?) {
        loadViewIfNeeded()
        directory = url
        watcher = DirectoryWatcher(url: url) { [weak self] in self?.reload() }
        load(url, selecting: selection.map { [$0.standardizedFileURL.path] } ?? [], keepScroll: false)
        content.focus()
    }

    private func reload() {
        guard let directory else { return }
        load(directory, selecting: selectedPaths, keepScroll: true)
    }

    private func load(_ url: URL, selecting paths: [String], keepScroll: Bool) {
        loadTask?.cancel()
        let started = ContinuousClock.now
        let showHidden = showHidden
        let order = sortOrder

        loadTask = Task { [weak self] in
            let result: Result<([FileEntry], [FileEntry]), Error>
            do {
                result = .success(try await Task.detached(priority: .userInitiated) {
                    let entries = try DirectoryLoader.loadSync(url)
                    return (entries, Sorting.arrange(entries, showHidden: showHidden, order: order))
                }.value)
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled, self.directory == url else { return }
            let loaded = ContinuousClock.now

            switch result {
            case .success(let (entries, arranged)):
                self.allEntries = entries
                self.apply(arranged, selecting: paths, keepScroll: keepScroll)
            case .failure(let error):
                self.allEntries = []
                self.apply([], selecting: [], keepScroll: false)
                self.showMessage("Can't open this folder.\n\(error.localizedDescription)")
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
    }

    private func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
    }

    // MARK: Selection and opening

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
}
