import Foundation

/// Finder's iCloud Drive merges the CloudDocs container with each app's "Documents" folder (its App Library).
public enum ICloudDrive {
    public struct Library: Equatable, Sendable {
        public let name: String
        public let url: URL
    }

    public static let mobileDocuments = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents", isDirectory: true)

    static let driveContainer = "com~apple~CloudDocs"

    static func isDriveRoot(_ url: URL) -> Bool {
        url.standardizedFileURL.lastPathComponent == driveContainer
    }

    /// macOS clears the hidden flag on exactly the containers Finder shows as App Libraries.
    public static func appLibraries(in mobileDocuments: URL = mobileDocuments) -> [FileEntry] {
        let containers = (try? FileManager.default.contentsOfDirectory(
            at: mobileDocuments, includingPropertiesForKeys: [.isHiddenKey, .localizedNameKey],
            options: .skipsHiddenFiles)) ?? []
        let keys = Set(DirectoryLoader.baseKeys + DirectoryLoader.cloudKeys)
        return containers.compactMap { container in
            guard container.lastPathComponent != driveContainer else { return nil }
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            guard FileManager.default.fileExists(atPath: documents.path) else { return nil }
            return DirectoryLoader.entry(for: documents, name: displayName(of: container), keys: keys, inCloud: true)
        }
    }

    /// The App Library a folder is in, given the path of its "Documents" folder or anything inside it.
    public static func library(containing url: URL, in mobileDocuments: URL = mobileDocuments) -> Library? {
        let root = mobileDocuments.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        let parts = path.dropFirst(root.count + 1).split(separator: "/")
        guard parts.count >= 2, parts[0] != driveContainer, parts[1] == "Documents" else { return nil }
        let container = mobileDocuments.appendingPathComponent(String(parts[0]), isDirectory: true)
        return Library(name: displayName(of: container),
                       url: container.appendingPathComponent("Documents", isDirectory: true))
    }

    public static func parent(of url: URL, in mobileDocuments: URL = mobileDocuments) -> URL {
        if let library = library(containing: url, in: mobileDocuments),
           library.url.standardizedFileURL.path == url.standardizedFileURL.path {
            return mobileDocuments.appendingPathComponent(driveContainer, isDirectory: true)
        }
        return url.deletingLastPathComponent()
    }

    private static func displayName(of container: URL) -> String {
        (try? container.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? container.lastPathComponent
    }
}
