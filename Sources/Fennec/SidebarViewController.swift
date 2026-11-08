import AppKit

@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case header(String)
        case place(Place)
    }

    var onNavigate: ((URL) -> Void)?

    private let tableView = NSTableView()
    private var rows: [Row] = []
    private var suppressSelection = false

    override func loadView() {
        let column = NSTableColumn(identifier: .init("place"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        view = scrollView

        reloadPlaces()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    func highlight(_ url: URL) {
        loadViewIfNeeded()
        suppressSelection = true
        defer { suppressSelection = false }
        let match = rows.firstIndex { row in
            if case .place(let place) = row { return Places.samePath(place.url, url) }
            return false
        }
        if let match {
            tableView.selectRowIndexes([match], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    @objc private func volumesChanged(_ notification: Notification) {
        reloadPlaces()
    }

    private func reloadPlaces() {
        rows = [.header("Places")] + Places.standard.map(Row.place)
            + [.header("Locations")] + Places.volumes.map(Row.place)
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .place = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = reuse("header", in: tableView, withImage: false)
            cell.textField?.stringValue = title
            return cell
        case .place(let place):
            let cell = reuse("place", in: tableView, withImage: true)
            cell.textField?.stringValue = place.name
            cell.imageView?.image = NSImage(systemSymbolName: place.symbol, accessibilityDescription: nil)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, tableView.selectedRow >= 0,
              case .place(let place) = rows[tableView.selectedRow] else { return }
        onNavigate?(place.url)
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
