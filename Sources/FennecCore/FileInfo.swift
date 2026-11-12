import Foundation

/// What the info panel shows for one item. Folder sizes come separately from `FileInfo.folderTotals`,
/// since adding them up can take a while.
public struct FileInfo: Sendable, Equatable {
    public let url: URL
    public let created: Date?
    public let modified: Date?
    public let owner: String?
    public let group: String?
    /// The POSIX permission bits, e.g. 0o644.
    public let permissions: Int?

    public init(url: URL, created: Date? = nil, modified: Date? = nil, owner: String? = nil,
                group: String? = nil, permissions: Int? = nil) {
        self.url = url
        self.created = created
        self.modified = modified
        self.owner = owner
        self.group = group
        self.permissions = permissions
    }

    public static func load(_ url: URL) -> FileInfo {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return FileInfo(
            url: url,
            created: values?.creationDate,
            modified: values?.contentModificationDate,
            owner: attributes?[.ownerAccountName] as? String,
            group: attributes?[.groupOwnerAccountName] as? String,
            permissions: (attributes?[.posixPermissions] as? NSNumber)?.intValue)
    }

    /// Bytes and number of items inside a folder or package, counting hidden files like Finder does.
    /// Returns nil once `isCancelled` says to stop.
    public static func folderTotals(
        _ url: URL, isCancelled: () -> Bool = { false }
    ) -> (bytes: Int64, items: Int)? {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return (0, 0) }
        var bytes: Int64 = 0
        var items = 0
        for case let child as URL in enumerator {
            if items % 256 == 0, isCancelled() { return nil }
            items += 1
            let values = try? child.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { bytes += Int64(values?.fileSize ?? 0) }
        }
        return (bytes, items)
    }
}

public enum FileInfoFormatting {
    /// "rwxr-xr-x" for 0o755.
    public static func permissions(_ mode: Int) -> String {
        let symbols: [Character] = ["r", "w", "x"]
        return String((0..<9).map { bit in
            mode & (1 << (8 - bit)) != 0 ? symbols[bit % 3] : "-"
        })
    }

    /// The folder an item is in, with the home folder shortened to ~.
    public static func location(of url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if parent == homePath { return "~" }
        if parent.hasPrefix(homePath + "/") { return "~" + parent.dropFirst(homePath.count) }
        return parent
    }

    /// The folders the items are in, in order and without repeats.
    public static func enclosingFolders(of urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.map { $0.standardizedFileURL.deletingLastPathComponent() }
            .filter { seen.insert($0.path).inserted }
    }

    /// "1.2 MB (1,234,567 bytes)", like Finder's info window.
    public static func size(_ bytes: Int64) -> String {
        let exact = bytes.formatted(.number.grouping(.automatic))
        let short = FileFormatting.bytes(bytes)
        return bytes < 1000 ? short : "\(short) (\(exact) bytes)"
    }

    /// The size line for a folder, e.g. "4 KB (4,096 bytes) for 3 items".
    public static func folderSize(bytes: Int64, items: Int) -> String {
        "\(size(bytes)) for \(items.formatted()) item\(items == 1 ? "" : "s")"
    }
}
