import FennecCore
import Foundation

struct Place {
    let name: String
    let symbol: String
    let url: URL
}

enum Places {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let iCloudDrive = home.appendingPathComponent(
        "Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)

    static var standard: [Place] {
        var places = [
            Place(name: "Home", symbol: "house", url: home),
            Place(name: "Desktop", symbol: "menubar.dock.rectangle", url: home.appendingPathComponent("Desktop")),
            Place(name: "Documents", symbol: "doc", url: home.appendingPathComponent("Documents")),
            Place(name: "Downloads", symbol: "arrow.down.circle", url: home.appendingPathComponent("Downloads")),
        ]
        if FileManager.default.fileExists(atPath: iCloudDrive.path) {
            places.append(Place(name: "iCloud Drive", symbol: "icloud", url: iCloudDrive))
        }
        places.append(Place(name: "Applications", symbol: "square.grid.2x2", url: URL(filePath: "/Applications")))
        places.append(Place(name: "Trash", symbol: "trash", url: FinderTrash.folder))
        return places
    }

    static var volumes: [Place] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let symbol: String
            if url.path == "/" {
                symbol = "internaldrive"
            } else if values?.volumeIsLocal == false {
                symbol = "network"
            } else {
                symbol = "externaldrive"
            }
            return Place(name: values?.volumeLocalizedName ?? url.lastPathComponent, symbol: symbol, url: url)
        }
    }

    @MainActor static var favorites: [Place] {
        PinnedFolders.favorites.paths.filter(isFolder).map { path in
            let url = URL(filePath: path, directoryHint: .isDirectory)
            let inCloud = url.path.hasPrefix(ICloudDrive.mobileDocuments.path)
            return Place(name: FileManager.default.displayName(atPath: path), symbol: inCloud ? "icloud" : "folder", url: url)
        }
    }

    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }
}

@MainActor
enum PinnedFolders {
    static let didChange = Notification.Name("PinnedFoldersDidChange")

    private(set) static var favorites = FavoritesStore.load(from: FavoritesStore.defaultURL)

    static func update(_ change: (inout Favorites) -> Void) {
        var updated = favorites
        change(&updated)
        guard updated != favorites else { return }
        favorites = updated
        try? FavoritesStore.save(updated, to: FavoritesStore.defaultURL)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
