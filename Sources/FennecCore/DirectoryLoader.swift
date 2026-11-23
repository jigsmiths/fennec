import Foundation

public enum DirectoryLoader {
    static let baseKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
        .contentModificationDateKey, .contentTypeKey, .isSymbolicLinkKey,
    ]

    // These go through the iCloud sync daemon, so only ask for them inside iCloud Drive.
    static let cloudKeys: [URLResourceKey] = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    public static func loadSync(_ directory: URL) throws -> [FileEntry] {
        if FinderTrash.isTrash(directory) {
            return try FinderTrash.items().map(entry(at:))
        }
        let inCloud = isInICloud(directory)
        let keys = inCloud ? baseKeys + cloudKeys : baseKeys
        var urls = try FileManager.default.contentsOfDirectory(
            at: listable(directory), includingPropertiesForKeys: keys)
        if isSymbolicLink(directory) {
            urls = urls.map { directory.appendingPathComponent($0.lastPathComponent) }
        }
        let keySet = Set(keys)
        var entries = urls.map { entry(for: $0, keys: keySet, inCloud: inCloud) }
        if ICloudDrive.isDriveRoot(directory) {
            entries += ICloudDrive.appLibraries(in: directory.deletingLastPathComponent())
        }
        return entries
    }

    public static func entry(at url: URL) -> FileEntry {
        let inCloud = isInICloud(url)
        return entry(for: url, keys: Set(inCloud ? baseKeys + cloudKeys : baseKeys), inCloud: inCloud)
    }

    public static func itemCount(at directory: URL, includeHidden: Bool) -> Int {
        let urls = try? FileManager.default.contentsOfDirectory(
            at: listable(directory), includingPropertiesForKeys: nil,
            options: includeHidden ? [] : [.skipsHiddenFiles])
        return urls?.count ?? 0
    }

    // contentsOfDirectory(at:) won't list through a symlink, so list its target instead.
    private static func listable(_ directory: URL) -> URL {
        isSymbolicLink(directory) ? directory.resolvingSymlinksInPath() : directory
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    public static func isInICloud(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }

    static func entry(for url: URL, name: String? = nil, keys: Set<URLResourceKey>, inCloud: Bool) -> FileEntry {
        let linkValues = try? url.resourceValues(forKeys: keys)
        var cloud = CloudStatus.none
        if inCloud, linkValues?.isUbiquitousItem == true {
            cloud = linkValues?.ubiquitousItemDownloadingStatus == .notDownloaded ? .notDownloaded : .current
        }
        var pointeeValues = linkValues
        if linkValues?.isSymbolicLink == true {
            pointeeValues = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: keys)) ?? linkValues
        }
        return FileEntry(
            url: url,
            name: name,
            isDirectory: pointeeValues?.isDirectory ?? false,
            isPackage: pointeeValues?.isPackage ?? false,
            isHidden: linkValues?.isHidden ?? false,
            size: pointeeValues?.fileSize.map(Int64.init),
            modified: pointeeValues?.contentModificationDate,
            typeIdentifier: pointeeValues?.contentType?.identifier,
            cloudStatus: cloud
        )
    }
}
