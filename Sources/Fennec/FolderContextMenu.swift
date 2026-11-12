import AppKit
import FennecCore

/// The right-click menu for the file list and grid. Items send the same actions as the main menu, so the
/// window controller runs and validates them for the active pane's selection.
@MainActor
enum FolderContextMenu {
    /// A menu for the selected items, or for the folder itself when nothing is selected.
    static func make(for entries: [FileEntry]) -> NSMenu {
        let menu = NSMenu()
        if entries.isEmpty {
            add(to: menu, [
                item("New Folder", #selector(MainWindowController.newFolder(_:))),
                .separator(),
                item("Get Info", #selector(MainWindowController.getInfo(_:))),
                item("Copy as Pathname", #selector(MainWindowController.copyPath(_:))),
                item("Copy Enclosing Folder Path", #selector(MainWindowController.copyEnclosingFolderPath(_:))),
                .separator(),
                item("Paste", #selector(MainWindowController.paste(_:))),
                .separator(),
                item("Show Hidden Files", #selector(MainWindowController.toggleHiddenFiles(_:))),
            ])
            return menu
        }

        menu.addItem(item("Open", #selector(MainWindowController.openSelection(_:))))
        if let openWith = openWithItem(for: entries) { menu.addItem(openWith) }
        if entries.count == 1, entries[0].isBrowsable {
            menu.addItem(item("Open in Other Pane", #selector(MainWindowController.openInOtherPane(_:))))
        }
        add(to: menu, [
            .separator(),
            item("Quick Look", #selector(MainWindowController.toggleQuickLook(_:))),
            item("Get Info", #selector(MainWindowController.getInfo(_:))),
            item("Rename", #selector(MainWindowController.renameSelection(_:))),
            .separator(),
            item("Copy", #selector(MainWindowController.copy(_:))),
            item("Cut", #selector(MainWindowController.cut(_:))),
            item("Copy as Pathname", #selector(MainWindowController.copyPath(_:))),
            item("Copy Enclosing Folder Path", #selector(MainWindowController.copyEnclosingFolderPath(_:))),
            .separator(),
            shareItem(for: entries),
            .separator(),
            item("Move to Trash", #selector(MainWindowController.moveToTrash(_:))),
        ])
        return menu
    }

    /// The system Share menu: AirDrop, Messages, Mail and any share extensions.
    private static func shareItem(for entries: [FileEntry]) -> NSMenuItem {
        let picker = NSSharingServicePicker(items: entries.map { $0.url as NSURL })
        let item = picker.standardShareMenuItem
        // Keep the picker alive for as long as the menu is.
        item.representedObject = picker
        return item
    }

    /// Apps that can open the first file, default app first. Nil for folders or when no app claims the file.
    private static func openWithItem(for entries: [FileEntry]) -> NSMenuItem? {
        guard let first = entries.first, entries.allSatisfy({ !$0.isBrowsable }) else { return nil }
        let workspace = NSWorkspace.shared
        let apps = workspace.urlsForApplications(toOpen: first.url)
        guard !apps.isEmpty else { return nil }
        let defaultApp = workspace.urlForApplication(toOpen: first.url)?.standardizedFileURL

        let submenu = NSMenu()
        var others: [NSMenuItem] = []
        var seen = Set<String>()
        for app in apps where seen.insert(app.standardizedFileURL.path).inserted {
            let isDefault = app.standardizedFileURL == defaultApp
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            let appItem = item(isDefault ? "\(name) (default)" : name, #selector(MainWindowController.openWith(_:)))
            appItem.representedObject = app
            let icon = workspace.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            appItem.image = icon
            if isDefault {
                submenu.addItem(appItem)
                submenu.addItem(.separator())
            } else {
                others.append(appItem)
            }
        }
        others.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.forEach(submenu.addItem)

        let holder = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        holder.submenu = submenu
        return holder
    }

    private static func add(to menu: NSMenu, _ items: [NSMenuItem]) {
        items.forEach(menu.addItem)
    }

    private static func item(_ title: String, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }
}
