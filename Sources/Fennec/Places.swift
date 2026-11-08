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

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }
}
