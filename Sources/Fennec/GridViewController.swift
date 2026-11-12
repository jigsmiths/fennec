import AppKit
import FennecCore
import QuickLookThumbnailing

final class GridCollectionView: NSCollectionView {
    var onOpen: (() -> Void)?
    var onRename: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onSwitchPane: (() -> Void)?
    var onFocus: (() -> Void)?
    /// A right-click on a tile, or on empty space (nil).
    var onMenu: ((IndexPath?) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?(indexPathForItem(at: convert(event.locationInWindow, from: nil)))
    }

    /// Whether selected tiles use the strong highlight: only while this grid has focus in the key window,
    /// like a table's selection.
    var isEmphasized: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
    }

    override func keyDown(with event: NSEvent) {
        if !handleFolderKey(event, onRename: onRename, onQuickLook: onQuickLook, onSwitchPane: onSwitchPane) {
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            refreshSelectionStyle()
            onFocus?()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // The window still reports this view as first responder until resigning returns, so restyle after.
        if resigned { DispatchQueue.main.async { [weak self] in self?.refreshSelectionStyle() } }
        return resigned
    }

    // Only our own observations: removeObserver(self) would also drop NSCollectionView's internal ones.
    private var keyObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSelectionStyle() }
            })
        }
    }

    private func refreshSelectionStyle() {
        for item in visibleItems() { (item as? GridItem)?.refreshSelectionStyle() }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, indexPathForItem(at: point) != nil {
            onOpen?()
        }
    }
}

@MainActor
final class GridViewController: NSViewController, FolderContentView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var onOpen: (() -> Void)?
    var onRename: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onFocus: (() -> Void)?
    var onSwitchPane: (() -> Void)?
    weak var dropHandler: FolderDropHandler?
    var onContextMenu: (() -> NSMenu?)?

    private let collectionView = GridCollectionView()
    private let scrollView = NSScrollView()
    private var rows: [FileEntry] = []

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 112, height: 108)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(GridItem.self, forItemWithIdentifier: GridItem.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.onOpen = { [weak self] in self?.onOpen?() }
        collectionView.onRename = { [weak self] in self?.onRename?() }
        collectionView.onQuickLook = { [weak self] in self?.onQuickLook?() }
        collectionView.onSwitchPane = { [weak self] in self?.onSwitchPane?() }
        collectionView.onFocus = { [weak self] in self?.onFocus?() }
        collectionView.onMenu = { [weak self] indexPath in self?.contextMenu(at: indexPath) }
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        view = scrollView
    }

    // MARK: FolderContentView

    var selectedIndexes: IndexSet {
        IndexSet(collectionView.selectionIndexPaths.map(\.item))
    }

    func display(_ newRows: [FileEntry], selecting indexes: IndexSet, keepScroll: Bool) {
        loadViewIfNeeded()
        let paths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        let update = {
            self.rows = newRows
            self.collectionView.reloadData()
            self.collectionView.selectionIndexPaths = paths
        }
        if keepScroll {
            scrollView.keepingScrollPosition(update)
            return
        }
        update()
        if let first = paths.min() {
            collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        } else {
            // The top sits above zero by the toolbar's content inset, so scroll to the top edge, not .zero.
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func focus() {
        view.window?.makeFirstResponder(collectionView)
    }

    func handleKey(_ event: NSEvent) {
        collectionView.keyDown(with: event)
    }

    func beginRename(at index: Int, onEnd: @escaping (String?) -> Void) {
        guard index < rows.count else { return onEnd(nil) }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
        collectionView.layoutSubtreeIfNeeded()
        guard let field = collectionView.item(at: indexPath)?.textField else { return onEnd(nil) }
        InlineRename.begin(
            on: field, name: rows[index].name, isFolder: rows[index].isBrowsable,
            returnFocusTo: collectionView, onEnd: onEnd)
    }

    func frame(ofItemAt index: Int) -> NSRect? {
        guard index < rows.count,
              let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
        else { return nil }
        return view.convert(frame, from: collectionView)
    }

    /// Like Finder: right-clicking an unselected tile selects just it, and empty space clears the selection.
    /// Setting the selection in code doesn't call the delegate, so report the change here.
    private func contextMenu(at indexPath: IndexPath?) -> NSMenu? {
        focus()
        let selection = collectionView.selectionIndexPaths
        if let indexPath {
            if !selection.contains(indexPath) { collectionView.selectionIndexPaths = [indexPath] }
        } else {
            collectionView.selectionIndexPaths = []
        }
        if collectionView.selectionIndexPaths != selection { onSelectionChange?() }
        return onContextMenu?()
    }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        rows[indexPath.item].url as NSURL
    }

    func collectionView(
        _ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        let folder = dropFolder(index: proposedIndexPath.pointee.item, operation: dropOperation.pointee)
        if folder == nil { dropOperation.pointee = .before }
        return dropHandler?.validateDrop(draggingInfo, onto: folder) ?? []
    }

    func collectionView(
        _ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        dropHandler?.acceptDrop(draggingInfo, onto: dropFolder(index: indexPath.item, operation: dropOperation)) ?? false
    }

    private func dropFolder(index: Int, operation: NSCollectionView.DropOperation) -> FileEntry? {
        guard operation == .on, index >= 0, index < rows.count, rows[index].isBrowsable else { return nil }
        return rows[index]
    }

    // MARK: Collection

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GridItem.reuseID, for: indexPath)
        (item as? GridItem)?.configure(rows[indexPath.item])
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChange?()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChange?()
    }
}

@MainActor
final class GridItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("grid")
    private static let iconSize: CGFloat = 64

    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var path: String?
    private var thumbnailRequest: QLThumbnailGenerator.Request?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8

        icon.imageScaling = .scaleProportionallyUpOrDown
        // NSImageView registers as a drop target for images and files, which stole drops meant for the grid.
        icon.unregisterDraggedTypes()
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true

        for subview in [icon, label] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
        ])
        view = container
        imageView = icon
        textField = label
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelection() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
    }

    func configure(_ entry: FileEntry) {
        cancelThumbnail()
        path = entry.path
        icon.image = FileDisplay.icon(for: entry)
        label.stringValue = entry.name
        view.alphaValue = entry.isHidden ? 0.55 : 1
        updateSelection()

        thumbnailRequest = ThumbnailCache.shared.thumbnail(for: entry, size: Self.iconSize) { [weak self] image in
            guard let self, self.path == entry.path else { return }
            self.icon.image = image
            self.thumbnailRequest = nil
        }
    }

    // A reused tile's old request would otherwise keep running and hold up the tiles on screen.
    private func cancelThumbnail() {
        if let thumbnailRequest { ThumbnailCache.shared.cancel(thumbnailRequest) }
        thumbnailRequest = nil
    }

    func refreshSelectionStyle() {
        updateSelection()
    }

    private func updateSelection() {
        let isDropTarget = highlightState == .asDropTarget
        let emphasized = (collectionView as? GridCollectionView)?.isEmphasized ?? true
        let selectionColor = emphasized || isDropTarget
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(isDropTarget ? 0.45 : 0.3)
            : NSColor.unemphasizedSelectedContentBackgroundColor
        view.layer?.backgroundColor = isSelected || isDropTarget ? selectionColor.cgColor : nil
        view.layer?.borderWidth = isDropTarget ? 2 : 0
        view.layer?.borderColor = NSColor.selectedContentBackgroundColor.cgColor
    }
}
