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
        let values = try? url.resourceValues(forKeys: keys)
        var cloud = CloudStatus.none
        if inCloud, values?.isUbiquitousItem == true {
            cloud = values?.ubiquitousItemDownloadingStatus == .notDownloaded ? .notDownloaded : .current
        }
        // A link keeps its own path and hidden flag, but looks like what it points at.
        var target = values
        if values?.isSymbolicLink == true {
            target = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: keys)) ?? values
        }
        return FileEntry(
            url: url,
            name: name,
            isDirectory: target?.isDirectory ?? false,
            isPackage: target?.isPackage ?? false,
            isHidden: values?.isHidden ?? false,
            size: target?.fileSize.map(Int64.init),
            modified: target?.contentModificationDate,
            typeIdentifier: target?.contentType?.identifier,
            cloudStatus: cloud
        )
    }
}
