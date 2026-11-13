import Foundation

/// Moves items to the Trash by asking Finder. macOS's own trash calls refuse iCloud items that another
/// app created (permission error 513) unless the caller is Finder, and Finder also records Put Back.
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

    // Converting a path to HFS text follows a symlink, so only the parent folder is converted and the
    // item is named inside it. Following links in the parent is harmless: it reaches the same item.
    static let locateHandler = """
        on locate(folderPath, itemName)
            return {(POSIX file folderPath) as text, itemName}
        end locate
        """

    // Paths arrive as arguments rather than in the script text, so no name can break the script.
    private static let script = locateHandler + """

        on run argv
            set trashed to {}
            repeat with i from 1 to (count argv) by 2
                set {folderPath, itemName} to locate(item i of argv, item (i + 1) of argv)
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

    /// Finder refuses to trash symlinks, so those take the system call, which moves the link itself.
    static func trash(
        _ urls: [URL], finder: ([URL]) throws -> [URL], system: (URL) throws -> URL
    ) throws -> [URL] {
        let isLink = urls.map { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true }
        let files = zip(urls, isLink).filter { !$0.1 }.map(\.0)
        var fromFinder = try (files.isEmpty ? [] : finder(files)).makeIterator()
        return try zip(urls, isLink).map { url, link in
            if link { return try system(url) }
            guard let trashed = fromFinder.next() else { throw Failure.finder("Finder didn't say where every item went.") }
            return trashed
        }
    }

    private static func systemTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    private static func askFinder(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments(for: urls)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure(fromStderr: stderr) }
        return try trashedURLs(from: stdout, count: urls.count)
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
