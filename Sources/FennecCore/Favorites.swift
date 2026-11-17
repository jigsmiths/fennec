import Foundation

/// The folders pinned to the sidebar, in the order the user arranged them.
public struct Favorites: Codable, Equatable, Sendable {
    public private(set) var paths: [String]

    public init(paths: [String] = []) {
        self.paths = []
        add(paths)
    }

    public func contains(_ path: String) -> Bool {
        paths.contains(Self.normalized(path))
    }

    /// Pins folders before `before` (or at the end when nil or not pinned), skipping ones already pinned.
    public mutating func add(_ newPaths: [String], before: String? = nil) {
        var index = before.flatMap { paths.firstIndex(of: Self.normalized($0)) } ?? paths.endIndex
        for path in newPaths.map(Self.normalized) where !paths.contains(path) {
            paths.insert(path, at: index)
            index += 1
        }
    }

    public mutating func remove(_ path: String) {
        paths.removeAll { $0 == Self.normalized(path) }
    }

    /// Moves a pinned folder before `before`, or to the end when nil.
    public mutating func move(_ path: String, before: String?) {
        let path = Self.normalized(path)
        guard paths.contains(path), path != before.map(Self.normalized) else { return }
        paths.removeAll { $0 == path }
        add([path], before: before)
    }

    static func normalized(_ path: String) -> String {
        URL(filePath: path).standardizedFileURL.path
    }
}

/// Saves the pinned folders next to the session file.
public enum FavoritesStore {
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Fennec/favorites.json")
    }

    /// The saved favorites, or none when the file is missing or unreadable.
    public static func load(from url: URL) -> Favorites {
        guard let data = try? Data(contentsOf: url),
              let favorites = try? JSONDecoder().decode(Favorites.self, from: data) else { return Favorites() }
        return Favorites(paths: favorites.paths)
    }

    public static func save(_ favorites: Favorites, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(favorites).write(to: url, options: .atomic)
    }
}
