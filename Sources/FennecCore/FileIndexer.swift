import Darwin
import Foundation
import UniformTypeIdentifiers

/// Lists everything under a folder for the fuzzy finder.
public enum FileIndexer {
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

    private static let skippedFolders: Set<String> = [".git", "node_modules"]

    /// Walks `root` breadth-first, so nearby items come first and one deep tree can't use up the whole `limit`.
    /// Hands over `batchSize` items at a time and stops after `limit` items or when the current task is cancelled.
    public static func walk(
        _ root: URL, includeHidden: Bool, limit: Int, batchSize: Int, onBatch: ([Item]) -> Void
    ) {
        let rootPath = root.path
        let reader = BulkReader()
        var packageExtensions: [String: Bool] = [:]
        let rootFolder = ""
        var pendingFolders = [rootFolder]
        var next = 0
        var batch: [Item] = []
        var count = 0

        while next < pendingFolders.count {
            let folderPath = pendingFolders[next]
            next += 1
            if Task.isCancelled { return }
            let fullPath = folderPath == rootFolder ? rootPath : rootPath + "/" + folderPath

            let outcome = reader.list(fullPath) { entry in
                let (name, isDirectory) = (entry.name, entry.isDirectory)
                if entry.isHidden, !includeHidden { return true }
                if isDirectory, skippedFolders.contains(name) { return true }
                let isPackage = isDirectory && hasPackageExtension(name, cache: &packageExtensions)
                let relative = folderPath == rootFolder ? name : folderPath + "/" + name
                if isDirectory, !isPackage { pendingFolders.append(relative) }

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

    public static func listsFolder(_ relativePath: String, includeHidden: Bool) -> Bool {
        var packageExtensions: [String: Bool] = [:]
        return relativePath.split(separator: "/").allSatisfy { component in
            let name = String(component)
            if name.hasPrefix("."), !includeHidden { return false }
            return !skippedFolders.contains(name) && !hasPackageExtension(name, cache: &packageExtensions)
        }
    }

    static func hasPackageExtension(_ name: String, cache: inout [String: Bool]) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if let known = cache[ext] { return known }
        let isPackage = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        cache[ext] = isPackage
        return isPackage
    }
}
