import Foundation

public enum DirectoryLoader {
    private static let baseKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
        .contentModificationDateKey, .contentTypeKey,
    ]

    // These go through the iCloud sync daemon, so only ask for them inside iCloud Drive.
    private static let cloudKeys: [URLResourceKey] = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    public static func loadSync(_ directory: URL) throws -> [FileEntry] {
        let inCloud = isInICloud(directory)
        let keys = inCloud ? baseKeys + cloudKeys : baseKeys
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)
        let keySet = Set(keys)
        return urls.map { entry(for: $0, keys: keySet, inCloud: inCloud) }
    }

    /// One item on its own, e.g. the folder being shown.
    public static func entry(at url: URL) -> FileEntry {
        let inCloud = isInICloud(url)
        return entry(for: url, keys: Set(inCloud ? baseKeys + cloudKeys : baseKeys), inCloud: inCloud)
    }

    public static func itemCount(at directory: URL, includeHidden: Bool) -> Int {
        let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: includeHidden ? [] : [.skipsHiddenFiles])
        return urls?.count ?? 0
    }

    public static func isInICloud(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }

    static func entry(for url: URL, keys: Set<URLResourceKey>, inCloud: Bool) -> FileEntry {
        let values = try? url.resourceValues(forKeys: keys)
        var cloud = CloudStatus.none
        if inCloud, values?.isUbiquitousItem == true {
            cloud = values?.ubiquitousItemDownloadingStatus == .notDownloaded ? .notDownloaded : .current
        }
        return FileEntry(
            url: url,
            isDirectory: values?.isDirectory ?? false,
            isPackage: values?.isPackage ?? false,
            isHidden: values?.isHidden ?? false,
            size: values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate,
            typeIdentifier: values?.contentType?.identifier,
            cloudStatus: cloud
        )
    }
}
