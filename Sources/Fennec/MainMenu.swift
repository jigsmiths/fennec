import AppKit

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("Fennec", [
            item("About Fennec", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Fennec", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Fennec", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("File", [
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n"),
            item("Open", #selector(MainWindowController.openSelection(_:)), arrow(NSDownArrowFunctionKey)),
            item("Quick Look", #selector(MainWindowController.toggleQuickLook(_:)), "y"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]))

        main.addItem(submenu("Edit", [
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
        ]))

        main.addItem(submenu("View", [
            item("as List", #selector(MainWindowController.showAsList(_:)), "1"),
            item("as Grid", #selector(MainWindowController.showAsGrid(_:)), "2"),
            .separator(),
            item("Show Preview", #selector(MainWindowController.togglePreview(_:)), "p", [.command, .shift]),
            item("Show Hidden Files", #selector(MainWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift]),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
        ]))

        var goItems: [NSMenuItem] = [
            item("Back", #selector(MainWindowController.goBack(_:)), "["),
            item("Forward", #selector(MainWindowController.goForward(_:)), "]"),
            item("Enclosing Folder", #selector(MainWindowController.goUp(_:)), arrow(NSUpArrowFunctionKey)),
            .separator(),
        ]
        let shortcuts: [String: (String, NSEvent.ModifierFlags)] = [
            "Home": ("h", [.command, .shift]),
            "Desktop": ("d", [.command, .shift]),
            "Documents": ("o", [.command, .shift]),
            "Downloads": ("l", [.command, .option]),
            "iCloud Drive": ("i", [.command, .shift]),
            "Applications": ("a", [.command, .shift]),
        ]
        for place in Places.standard {
            let shortcut = shortcuts[place.name]
            let goItem = item(place.name, #selector(MainWindowController.goToPlace(_:)),
                              shortcut?.0 ?? "", shortcut?.1 ?? [.command])
            goItem.representedObject = place.url
            goItems.append(goItem)
        }
        main.addItem(submenu("Go", goItems))

        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu

        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt16(key))!))
    }
}
