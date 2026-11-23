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

    /// How far a walk has got: everything counted so far, and the folder it's in, relative to the root.
    public struct Progress: Sendable, Equatable {
        public let files: Int64
        public let bytes: Int64
        public let folder: String

        public init(files: Int64, bytes: Int64, folder: String) {
            self.files = files
            self.bytes = bytes
            self.folder = folder
        }

        /// Progress toward the file count of the last walk, held below 1 since the folder may have grown since.
        public func fraction(ofExpected expected: Int64?) -> Double? {
            guard let expected, expected > 0 else { return nil }
            return min(Double(files) / Double(expected), 0.99)
        }
    }

    /// Returns nil once `isCancelled` says to stop. `progress` is called on the walking thread, at most once
    /// per `progressInterval`.
    public static func walk(
        _ root: URL, now: Date = Date(), isCancelled: () -> Bool = { false },
        progressInterval: Duration = .milliseconds(100), progress: ((Progress) -> Void)? = nil
    ) -> FolderWalk? {
        let reader = BulkReader(details: true)
        let clock = ContinuousClock()
        var walk = FolderWalk()
        var packageExtensions: [String: Bool] = [:]
        let rootPath = root.standardizedFileURL.path
        let relativeStart = rootPath == "/" ? 1 : rootPath.count + 1
        var scannedFiles: Int64 = 0
        var scannedBytes: Int64 = 0
        var lastReport = clock.now

        func visit(_ path: String, record: Int?, recordInside: Bool, modified: Int64) -> Totals? {
            if isCancelled() { return nil }
            let start = clock.now
            var totals = Totals(newest: modified)
            var folders: [BulkReader.Entry] = []
            let outcome = reader.list(path) { entry in
                let details = entry.details ?? .init()
                if entry.isDirectory {
                    if !details.isMountPoint { folders.append(entry) }
                } else {
                    totals.files += 1
                    totals.bytes += details.size
                    totals.allocated += details.allocated
                    totals.newest = max(totals.newest, details.modified)
                }
                return true
            }
            if outcome == .failed { totals.incomplete = true }
            scannedFiles += totals.files
            scannedBytes += totals.bytes
            if let progress, start - lastReport >= progressInterval {
                lastReport = start
                let folder = path.count > relativeStart ? String(path.dropFirst(relativeStart)) : ""
                progress(Progress(files: scannedFiles, bytes: scannedBytes, folder: folder))
            }

            for folder in folders {
                var childRecord: Int?
                if recordInside, let record {
                    childRecord = walk.folders.count
                    walk.folders.append(.init(parent: record, name: folder.name, stats: FolderStats(calculated: now)))
                }
                let isPackage = FileIndexer.hasPackageExtension(folder.name, cache: &packageExtensions)
                let childPath = path == "/" ? "/" + folder.name : path + "/" + folder.name
                guard let inner = visit(
                    childPath, record: childRecord, recordInside: childRecord != nil && !isPackage,
                    modified: folder.details?.modified ?? 0)
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

        let rootModified = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate.map { Int64($0.timeIntervalSince1970) } ?? 0
        walk.folders.append(.init(parent: -1, name: root.lastPathComponent, stats: FolderStats(calculated: now)))
        let rootIsPackage = FileIndexer.hasPackageExtension(root.lastPathComponent, cache: &packageExtensions)
        guard visit(rootPath, record: 0, recordInside: !rootIsPackage, modified: rootModified) != nil
        else { return nil }
        return walk
    }
}
