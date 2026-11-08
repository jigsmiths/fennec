import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [MainWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        openWindow(at: startDirectory())
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(at: Places.home)
    }

    private func openWindow(at url: URL) {
        let controller = MainWindowController(start: url)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        windows.append(controller)
        controller.showWindow(nil)
    }

    private func startDirectory() -> URL {
        let argument = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
        var isDirectory: ObjCBool = false
        if let argument, FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return URL(filePath: argument, directoryHint: .isDirectory)
        }
        return Places.home
    }
}
