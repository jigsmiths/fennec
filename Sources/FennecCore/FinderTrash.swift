import Foundation

/// Moves items to the Trash. macOS's own trash call can refuse iCloud items that another app created
/// (permission error 513) unless the caller is Finder, so those are handed to Finder.
public enum FinderTrash {
    public enum Failure: Error, Equatable, LocalizedError {
        case automationDenied
        case finder(String)

        public var errorDescription: String? {
            switch self {
            case .automationDenied:
                "Fennec isn't allowed to control Finder, which it uses to move items to the Trash. "
                    + "Allow it in System Settings › Privacy & Security › Automation."
            case .finder(let message):
                message
            }
        }
    }

    private static let script = """
        on run argv
            set trashed to {}
            repeat with i from 1 to (count argv) by 2
                set folderPath to (POSIX file (item i of argv)) as text
                set itemName to item (i + 1) of argv
                tell application "Finder" to set t to delete item itemName of folder folderPath
                set end of trashed to POSIX path of (t as alias)
            end repeat
            set AppleScript's text item delimiters to linefeed
            return trashed as text
        end run
        """

    /// Parent folder and name for each item. Finder shows a ":" in a file name as "/".
    static func arguments(for urls: [URL]) -> [String] {
        urls.flatMap { url in
            [url.deletingLastPathComponent().path, url.lastPathComponent.replacingOccurrences(of: ":", with: "/")]
        }
    }

    public static func trash(_ urls: [URL]) throws -> [URL] {
        try trash(urls, finder: askFinder, system: systemTrash)
    }

    /// The Trash as the sidebar and panes show it. Its real contents span several folders.
    public static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".Trash", isDirectory: true)

    public static func isTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.path == folder.standardizedFileURL.path
    }

    /// Folders here can't be listed without Full Disk Access.
    public static func isInsideHomeTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// macOS privacy blocks come back as EPERM; ordinary folder permissions are EACCES.
    public static func needsFullDiskAccess(_ error: Error, opening url: URL) -> Bool {
        guard isInsideHomeTrash(url) else { return false }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(EPERM)
    }

    /// Everything in the Trash, from every trash folder (home, iCloud Drive, other disks). Listing ~/.Trash
    /// directly needs Full Disk Access, but Finder can list it.
    public static func items() throws -> [URL] {
        itemURLs(from: try runFinder("tell application \"Finder\" to set found to URL of every item of trash\n"
            + "set AppleScript's text item delimiters to linefeed\nfound as text", arguments: []))
    }

    static func itemURLs(from output: String) -> [URL] {
        output.split(separator: "\n").compactMap { URL(string: String($0)) }.filter(\.isFileURL)
    }

    public static func empty() throws {
        _ = try runFinder("tell application \"Finder\" to empty trash", arguments: [])
    }

    /// Finder's scripting can't trash undownloaded iCloud folders or symlinks, so it only gets other items the system refuses.
    static func trash(
        _ urls: [URL], finder: ([URL]) throws -> [URL], system: (URL) throws -> URL
    ) throws -> [URL] {
        var trashed: [URL?] = []
        var refused: [Int] = []
        for (index, url) in urls.enumerated() {
            do {
                trashed.append(try system(url))
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileWriteNoPermissionError && !isSymbolicLink(url) {
                trashed.append(nil)
                refused.append(index)
            }
        }
        if !refused.isEmpty {
            let fromFinder = try finder(refused.map { urls[$0] })
            guard fromFinder.count == refused.count else { throw Failure.finder("Finder didn't say where every item went.") }
            for (index, url) in zip(refused, fromFinder) { trashed[index] = url }
        }
        return trashed.compactMap { $0 }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func systemTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    private static func askFinder(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty else { return [] }
        return try trashedURLs(from: runFinder(script, arguments: arguments(for: urls)), count: urls.count)
    }

    private static func runFinder(_ script: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure(fromStderr: stderr) }
        return stdout
    }

    static func trashedURLs(from output: String, count: Int) throws -> [URL] {
        let urls = output.split(separator: "\n").map { URL(filePath: String($0)) }
        guard urls.count == count else { throw Failure.finder("Finder didn't say where every item went.") }
        return urls
    }

    static func failure(fromStderr stderr: String) -> Failure {
        let pattern = /execution error: (.*) \((-?\d+)\)/
        guard let match = stderr.firstMatch(of: pattern) else {
            return .finder(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return match.2 == "-1743" ? .automationDenied : .finder(String(match.1))
    }
}
