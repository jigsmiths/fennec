import Foundation

/// Stats for a folder and every folder under it, from one walk.
public struct FolderWalk: Sendable {
    public struct Folder: Sendable {
        /// The parent's index in `folders`, or -1 for the root.
        public let parent: Int
        public let name: String
        public var stats: FolderStats
    }

    /// The root comes first, and every folder comes after its parent.
    public internal(set) var folders: [Folder] = []
}

/// Totals up folders the way Finder's Get Info does: hidden files count, symlinks count as small files and
/// aren't followed. Packages get a row of their own but the folders inside them don't, since nobody browses
/// into them. Other volumes mounted inside aren't entered, so walking "/" doesn't wander onto network drives.
public enum FolderWalker {
    private struct Totals {
        var bytes: Int64 = 0
        var allocated: Int64 = 0
        var files: Int64 = 0
        var subfolders: Int64 = 0
        var newest: Int64 = 0
        var incomplete = false

        mutating func add(_ other: Totals) {
            bytes += other.bytes
            allocated += other.allocated
            files += other.files
            subfolders += other.subfolders
            newest = max(newest, other.newest)
            incomplete = incomplete || other.incomplete
        }
    }

    /// Returns nil once `isCancelled` says to stop.
    public static func walk(_ root: URL, now: Date = Date(), isCancelled: () -> Bool = { false }) -> FolderWalk? {
        let reader = BulkReader(details: true)
        let clock = ContinuousClock()
        var walk = FolderWalk()
        var packageExtensions: [String: Bool] = [:]

        func visit(_ path: String, record: Int?, recordInside: Bool, modified: Int64) -> Totals? {
            if isCancelled() { return nil }
            let start = clock.now
            var totals = Totals(newest: modified)
            var folders: [BulkReader.Entry] = []
            let outcome = reader.list(path) { entry in
                if entry.isDirectory {
                    if !entry.isMountPoint { folders.append(entry) }
                } else {
                    totals.files += 1
                    totals.bytes += entry.size
                    totals.allocated += entry.allocated
                    totals.newest = max(totals.newest, entry.modified)
                }
                return true
            }
            if outcome == .failed { totals.incomplete = true }

            for folder in folders {
                var childRecord: Int?
                if recordInside, let record {
                    childRecord = walk.folders.count
                    walk.folders.append(.init(parent: record, name: folder.name, stats: FolderStats(calculated: now)))
                }
                let isPackage = FileIndexer.isPackageName(folder.name, cache: &packageExtensions)
                let childPath = path == "/" ? "/" + folder.name : path + "/" + folder.name
                guard let inner = visit(
                    childPath, record: childRecord, recordInside: childRecord != nil && !isPackage,
                    modified: folder.modified)
                else { return nil }
                totals.subfolders += 1
                totals.add(inner)
            }

            if let record {
                let (seconds, attoseconds) = start.duration(to: clock.now).components
                walk.folders[record].stats = FolderStats(
                    bytes: totals.bytes, allocated: totals.allocated, files: totals.files,
                    subfolders: totals.subfolders,
                    newest: totals.newest > 0 ? Date(timeIntervalSince1970: Double(totals.newest)) : nil,
                    calculated: now, durationMilliseconds: seconds * 1000 + attoseconds / 1_000_000_000_000_000,
                    incomplete: totals.incomplete)
            }
            return totals
        }

        let rootPath = root.standardizedFileURL.path
        let rootModified = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate.map { Int64($0.timeIntervalSince1970) } ?? 0
        walk.folders.append(.init(parent: -1, name: root.lastPathComponent, stats: FolderStats(calculated: now)))
        let rootIsPackage = FileIndexer.isPackageName(root.lastPathComponent, cache: &packageExtensions)
        guard visit(rootPath, record: 0, recordInside: !rootIsPackage, modified: rootModified) != nil
        else { return nil }
        return walk
    }
}
