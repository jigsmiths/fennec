import Foundation

/// Typed paths for Go to Folder: where they lead, and which folders could complete them.
public enum PathEntry {
    public enum Target: Sendable {
        case folder(URL)
        /// A file or package, to show selected in its folder.
        case item(URL)
        case notFound
    }

    /// Typed text split at its last slash: the folder to list and the name being typed in it.
    public struct Query: Equatable, Sendable {
        public let folder: URL
        /// The text up to and including the last slash, kept as typed.
        public let typedFolder: String
        public let partial: String
    }

    public struct Suggestion: Equatable, Sendable {
        /// The name Finder shows, e.g. an App Library's app name.
        public let name: String
        public let url: URL
        /// The matched part of `name`, in UTF-16 units.
        public let matchRange: NSRange
        /// The field text after choosing this suggestion.
        public let completion: String
    }

    public static let defaultHome = FileManager.default.homeDirectoryForCurrentUser

    public static func resolve(_ text: String, relativeTo base: URL, home: URL = defaultHome) -> Target {
        guard !text.isEmpty else { return .notFound }
        let url = expand(text, relativeTo: base, home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return .notFound }
        return DirectoryLoader.entry(at: url).isBrowsable ? .folder(url) : .item(url)
    }

    public static func query(for text: String, relativeTo base: URL, home: URL = defaultHome) -> Query {
        guard let slash = text.lastIndex(of: "/") else {
            return Query(folder: base.standardizedFileURL, typedFolder: "", partial: text)
        }
        let typedFolder = String(text[...slash])
        return Query(folder: expand(typedFolder, relativeTo: base, home: home), typedFolder: typedFolder,
                     partial: String(text[text.index(after: slash)...]))
    }

    /// The folders in a folder, with iCloud Drive's App Libraries merged in like Finder. Empty if it can't be read.
    public static func folders(in folder: URL) -> [FileEntry] {
        ((try? DirectoryLoader.loadSync(folder)) ?? []).filter(\.isBrowsable)
    }

    /// Folders whose names start with the typed name, then those that contain it, each alphabetically.
    public static func suggestions(_ query: Query, in folders: [FileEntry], includeHidden: Bool, limit: Int,
                                   home: URL = defaultHome) -> [Suggestion] {
        let showHidden = includeHidden || query.partial.hasPrefix(".")
        let matches: [(entry: FileEntry, range: NSRange)] = folders.compactMap { entry in
            guard showHidden || !entry.isHidden else { return nil }
            if query.partial.isEmpty { return (entry, NSRange(location: 0, length: 0)) }
            let range = (entry.name as NSString).range(of: query.partial, options: .caseInsensitive)
            return range.location == NSNotFound ? nil : (entry, range)
        }
        let sorted = matches.sorted { a, b in
            let aPrefix = a.range.location == 0, bPrefix = b.range.location == 0
            if aPrefix != bPrefix { return aPrefix }
            return a.entry.name.localizedStandardCompare(b.entry.name) == .orderedAscending
        }
        let folderPath = query.folder.standardizedFileURL.path
        return sorted.prefix(limit).map { entry, range in
            let inFolder = entry.url.deletingLastPathComponent().standardizedFileURL.path == folderPath
            let completion = inFolder
                ? query.typedFolder + entry.url.lastPathComponent + "/"
                : abbreviated(entry.url, home: home) + "/"
            return Suggestion(name: entry.name, url: entry.url, matchRange: range, completion: completion)
        }
    }

    static func expand(_ text: String, relativeTo base: URL, home: URL) -> URL {
        let url: URL
        if text == "~" {
            url = home
        } else if text.hasPrefix("~/") {
            url = home.appendingPathComponent(String(text.dropFirst(2)))
        } else if text.hasPrefix("/") {
            url = URL(fileURLWithPath: text)
        } else {
            url = base.appendingPathComponent(text)
        }
        return url.standardizedFileURL
    }

    public static func abbreviated(_ url: URL, home: URL = defaultHome) -> String {
        let path = url.standardizedFileURL.path, homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }
}
