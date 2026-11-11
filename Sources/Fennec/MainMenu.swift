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

        // Cmd+Down opens too, like Finder; hidden so the menu shows one Open item.
        let openWithArrow = item("Open", #selector(MainWindowController.openSelection(_:)), arrow(NSDownArrowFunctionKey))
        openWithArrow.isHidden = true
        openWithArrow.allowsKeyEquivalentWhenHidden = true

        main.addItem(submenu("File", [
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n"),
            item("New Folder", #selector(MainWindowController.newFolder(_:)), "n", [.command, .shift]),
            .separator(),
            item("Open", #selector(MainWindowController.openSelection(_:)), "o"),
            openWithArrow,
            item("Rename", #selector(MainWindowController.renameSelection(_:))),
            item("Quick Look", #selector(MainWindowController.toggleQuickLook(_:)), "y"),
            .separator(),
            item("Move to Trash", #selector(MainWindowController.moveToTrash(_:)), backspace),
            item("Delete Immediately…", #selector(MainWindowController.deleteImmediately(_:)), backspace,
                 [.command, .option]),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Move Item Here", #selector(MainWindowController.pasteAsMove(_:)), "v", [.command, .option]),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
            .separator(),
            item("Copy to Other Pane", #selector(MainWindowController.copyToOtherPane(_:)), "c", [.command, .shift]),
            item("Move to Other Pane", #selector(MainWindowController.moveToOtherPane(_:)), "m", [.command, .shift]),
        ]))

        main.addItem(submenu("View", [
            item("as List", #selector(MainWindowController.showAsList(_:)), "1"),
            item("as Grid", #selector(MainWindowController.showAsGrid(_:)), "2"),
            .separator(),
            item("Split Panes", #selector(MainWindowController.toggleSplit(_:)), "u"),
            item("Open in Other Pane", #selector(MainWindowController.openInOtherPane(_:)), "o", [.command, .option]),
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

        let helpMenu = submenu("Help", [
            item("Keyboard Shortcuts", #selector(AppDelegate.showShortcuts(_:)), "/"),
        ])
        main.addItem(helpMenu)
        NSApp.helpMenu = helpMenu.submenu

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

    /// The Delete key in a menu shortcut (Cmd+Delete for Move to Trash).
    private static let backspace = String(Character(UnicodeScalar(UInt8(NSBackspaceCharacter))))
}
