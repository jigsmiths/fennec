import Darwin
import Foundation
import UniformTypeIdentifiers

/// Lists everything under a folder for the fuzzy finder.
public enum FileIndexer {
    /// No URL is stored: an NSURL costs about 500 bytes, and the finder only needs one for the item it opens.
    public struct Item: Sendable {
        public let isDirectory: Bool
        public let isBrowsable: Bool
        /// The path relative to the searched folder, ready to match.
        public let candidate: FuzzyMatcher.Candidate

        public var relativePath: String { candidate.text }

        public func url(in root: URL) -> URL {
            root.appendingPathComponent(relativePath, isDirectory: isDirectory)
        }
    }

    /// Big, rarely wanted trees that would crowd out real results.
    private static let skippedFolders: Set<String> = [".git", "node_modules"]

    /// Walks `root` breadth-first, so nearby items come first and one deep tree can't use up the whole `limit`.
    /// Hands over `batchSize` items at a time and stops after `limit` items or when the current task is cancelled.
    public static func walk(
        _ root: URL, includeHidden: Bool, limit: Int, batchSize: Int, onBatch: ([Item]) -> Void
    ) {
        let rootPath = root.path
        let reader = BulkReader()
        var packageExtensions: [String: Bool] = [:]
        // Folders still to list, relative to root; "" is the root itself.
        var queue = [""]
        var next = 0
        var batch: [Item] = []
        var count = 0

        while next < queue.count {
            let folderPath = queue[next]
            next += 1
            if Task.isCancelled { return }
            let fullPath = folderPath.isEmpty ? rootPath : rootPath + "/" + folderPath

            let outcome = reader.list(fullPath) { entry in
                let (name, isDirectory) = (entry.name, entry.isDirectory)
                if entry.isHidden, !includeHidden { return true }
                if isDirectory, skippedFolders.contains(name) { return true }
                let isPackage = isDirectory && isPackageName(name, cache: &packageExtensions)
                let relative = folderPath.isEmpty ? name : folderPath + "/" + name
                if isDirectory, !isPackage { queue.append(relative) }

                batch.append(Item(
                    isDirectory: isDirectory, isBrowsable: isDirectory && !isPackage,
                    candidate: FuzzyMatcher.Candidate(relative)))
                count += 1
                if batch.count == batchSize {
                    onBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                }
                return count < limit
            }
            if outcome == .stopped { break }
        }
        if !batch.isEmpty { onBatch(batch) }
    }

    /// Packages (.app, .bundle, .xcodeproj…) are recognized by extension, as Launch Services does for nearly all.
    static func isPackageName(_ name: String, cache: inout [String: Bool]) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if let known = cache[ext] { return known }
        let isPackage = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        cache[ext] = isPackage
        return isPackage
    }
}
