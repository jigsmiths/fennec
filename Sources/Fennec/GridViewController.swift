import AppKit
import FennecCore
import QuickLookThumbnailing

final class GridCollectionView: NSCollectionView {
    var onOpen: (() -> Void)?
    var onQuickLook: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if !handleFolderKey(event, onOpen: onOpen, onQuickLook: onQuickLook) {
            super.keyDown(with: event)
        }
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
    var onSelectionChange: (() -> Void)?
    var onQuickLook: (() -> Void)?

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
        collectionView.onQuickLook = { [weak self] in self?.onQuickLook?() }

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

    private func updateSelection() {
        view.layer?.backgroundColor = isSelected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).cgColor
            : nil
    }
}
