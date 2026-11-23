import AppKit
import FennecCore

@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Row {
        case header(String)
        case favorite(Place)
        case place(Place)

        var place: Place? {
            switch self {
            case .header: nil
            case .favorite(let place), .place(let place): place
            }
        }
    }

    private static let favoriteType = NSPasteboard.PasteboardType("dev.fennec.favorite")

    var onNavigate: ((URL) -> Void)?

    private let tableView = NSTableView()
    private var rows: [Row] = []
    private var favorites: [Place] = []
    private var highlighted: URL?
    private var suppressSelection = false

    override func loadView() {
        let column = NSTableColumn(identifier: .init("place"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.favoriteType, .fileURL])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .gap

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        view = scrollView

        reloadPlaces()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(placesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(placesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(placesChanged(_:)), name: PinnedFolders.didChange, object: nil)
    }

    func highlight(_ url: URL) {
        loadViewIfNeeded()
        highlighted = url
        suppressSelection = true
        defer { suppressSelection = false }
        let match = rows.firstIndex { row in row.place.map { Places.samePath($0.url, url) } ?? false }
        if let match {
            tableView.selectRowIndexes([match], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    @objc private func placesChanged(_ notification: Notification) {
        reloadPlaces()
    }

    private func reloadPlaces() {
        favorites = Places.favorites
        let favoriteRows = favorites.isEmpty ? [] : [.header("Favorites")] + favorites.map(Row.favorite)
        rows = favoriteRows + [.header("Places")] + Places.standard.map(Row.place)
            + [.header("Locations")] + Places.volumes.map(Row.place)
        tableView.reloadData()
        if let highlighted { highlight(highlighted) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].place != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = reuse("header", in: tableView, withImage: false)
            cell.textField?.stringValue = title
            return cell
        case .favorite(let place), .place(let place):
            let cell = reuse("place", in: tableView, withImage: true)
            cell.textField?.stringValue = place.name
            cell.imageView?.image = NSImage(systemSymbolName: place.symbol, accessibilityDescription: nil)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, tableView.selectedRow >= 0,
              let place = rows[tableView.selectedRow].place else { return }
        onNavigate?(place.url)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, case .favorite(let place) = rows[row] else { return }
        let remove = NSMenuItem(title: "Remove from Sidebar", action: #selector(removeFavorite(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = place.url
        menu.addItem(remove)
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        PinnedFolders.update { $0.remove(url.path) }
    }

    private var favoritesHeaderRows: Int { favorites.isEmpty ? 0 : 1 }

    private var favoriteGaps: ClosedRange<Int> {
        favoritesHeaderRows...(favoritesHeaderRows + favorites.count)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .favorite(let place) = rows[row] else { return nil }
        let item = NSPasteboardItem()
        item.setString(place.url.path, forType: Self.favoriteType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        let operation: NSDragOperation
        if draggedFavorite(info) != nil {
            operation = .move
        } else if !draggedFolders(info).isEmpty {
            operation = [.link, .generic, .copy].first(where: mask.contains) ?? []
        } else {
            return []
        }
        let gaps = favoriteGaps
        tableView.setDropRow(min(max(row, gaps.lowerBound), gaps.upperBound), dropOperation: .above)
        return operation
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let index = row - favoriteGaps.lowerBound
        let before = index < favorites.count ? favorites[index].url.path : nil
        if let dragged = draggedFavorite(info) {
            PinnedFolders.update { $0.move(dragged, before: before) }
            return true
        }
        let folders = draggedFolders(info)
        guard !folders.isEmpty else { return false }
        PinnedFolders.update { $0.add(folders.map(\.path), before: before) }
        return true
    }

    private func draggedFavorite(_ info: NSDraggingInfo) -> String? {
        info.draggingPasteboard.string(forType: Self.favoriteType)
    }

    private func draggedFolders(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let allFolders = urls.allSatisfy { url in
            Places.isFolder(url.path) && !NSWorkspace.shared.isFilePackage(atPath: url.path)
        }
        return allFolders ? urls : []
    }

    private func reuse(_ id: String, in tableView: NSTableView, withImage: Bool) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        var leading = cell.leadingAnchor
        if withImage {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
            ])
            leading = image.trailingAnchor
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: withImage ? 6 : 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
