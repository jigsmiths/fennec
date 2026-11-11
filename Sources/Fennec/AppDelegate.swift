import AppKit
import FennecCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [MainWindowController] = []
    /// Off when launched on a folder from the command line (bench, test runs), so those never replace
    /// the real session.
    private var savesSession = true
    private var saveTask: Task<Void, Never>?
    /// FENNEC_SESSION_FILE lets test runs use a scratch session instead of the real one.
    private let sessionURL = ProcessInfo.processInfo.environment["FENNEC_SESSION_FILE"]
        .map { URL(filePath: $0) } ?? SessionStore.defaultURL

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        if let folder = folderArgument() {
            savesSession = false
            openWindow(WindowDefaults.window(at: folder))
        } else {
            let session = SessionStore.load(from: sessionURL, fallback: Places.home)
            for state in session.windows { openWindow(state) }
            if windows.isEmpty { openWindow(WindowDefaults.window(at: Places.home)) }
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Save before quitting closes the windows: each close removes its window, which would leave an empty session.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveSession()
        savesSession = false
        return .terminateNow
    }

    // Fennec restores windows from its own session file. Opting out of macOS's restoration also stops its
    // "reopen windows?" prompt after a crash, which blocks launch until answered.
    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    @objc func newWindow(_ sender: Any?) {
        let current = (NSApp.keyWindow?.windowController as? MainWindowController)?.activeFolder
        openWindow(WindowDefaults.window(at: current ?? Places.home))
    }

    @objc func showShortcuts(_ sender: Any?) {
        ShortcutsWindowController.shared.show()
    }

    private func openWindow(_ state: WindowState) {
        let controller = MainWindowController(state: state)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
            self?.saveSession()
        }
        controller.onStateChange = { [weak self] in self?.scheduleSave() }
        windows.append(controller)
        controller.showWindow(nil)
        scheduleSave()
    }

    // MARK: Session

    /// Saves shortly after a burst of changes rather than on every one.
    private func scheduleSave() {
        guard savesSession else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }

    private func saveSession() {
        guard savesSession else { return }
        saveTask?.cancel()
        let state = SessionState(windows: windows.map(\.windowState))
        try? SessionStore.save(state, to: sessionURL)
    }

    private func folderArgument() -> URL? {
        let argument = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
        var isDirectory: ObjCBool = false
        guard let argument, FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(filePath: argument, directoryHint: .isDirectory)
    }
}
