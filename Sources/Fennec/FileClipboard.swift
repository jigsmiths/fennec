import AppKit

/// Copy and cut through the general pasteboard as file URLs, so Finder and other apps can paste them too.
/// A cut adds a private marker type; pasting a marked clipboard moves instead of copying.
@MainActor
enum FileClipboard {
    private static let cutMarker = NSPasteboard.PasteboardType("dev.bvdwalt.fennec.cut")
    private static let fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    static func write(_ urls: [URL], cut: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        if cut {
            pasteboard.addTypes([cutMarker], owner: nil)
            pasteboard.setString("1", forType: cutMarker)
        }
    }

    /// Paths as plain text, one per line, for pasting into a terminal or editor.
    static func writePaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func read() -> (urls: [URL], isCut: Bool) {
        let pasteboard = NSPasteboard.general
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLsOnly) as? [URL] ?? []
        return (urls, pasteboard.types?.contains(cutMarker) == true)
    }

    static var hasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: fileURLsOnly)
    }

    /// After a cut is pasted the originals are gone, so the clipboard shouldn't offer them again.
    static func clear() {
        NSPasteboard.general.clearContents()
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLsOnly) as? [URL] ?? []
    }
}
