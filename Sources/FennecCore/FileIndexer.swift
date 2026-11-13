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

            let reachedLimit = reader.list(fullPath) { name, isDirectory, isHidden in
                if isHidden, !includeHidden { return true }
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
            if reachedLimit { break }
        }
        if !batch.isEmpty { onBatch(batch) }
    }

    /// Packages (.app, .bundle, .xcodeproj…) are recognized by extension, as Launch Services does for nearly all.
    private static func isPackageName(_ name: String, cache: inout [String: Bool]) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if let known = cache[ext] { return known }
        let isPackage = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        cache[ext] = isPackage
        return isPackage
    }
}

/// Reads a folder's entries with getattrlistbulk: names, types and the hidden flag come back in a few system
/// calls per folder, instead of an NSURL and a property lookup per entry.
private final class BulkReader {
    private static let bufferSize = 64 * 1024
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
    private var attributes: attrlist = {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FLAGS)
        return list
    }()

    deinit { buffer.deallocate() }

    /// Calls `entry(name, isDirectory, isHidden)` for each entry until it returns false. Symlinks count as files,
    /// so they're never followed. Returns true if `entry` stopped the listing.
    func list(_ path: String, entry: (String, Bool, Bool) -> Bool) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, Self.bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            guard count > 0 else { return false }
            var record = buffer
            for _ in 0..<count {
                // Layout, in the requested attributes' order: length, returned set, name ref, type, flags.
                let length = record.loadUnaligned(as: UInt32.self)
                var field = record + MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let name = String(cString: (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size
                let type = field.loadUnaligned(as: fsobj_type_t.self)
                field += MemoryLayout<fsobj_type_t>.size
                let flags = field.loadUnaligned(as: UInt32.self)
                record += Int(length)

                let isDirectory = type == fsobj_type_t(VDIR.rawValue)
                let isHidden = name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0
                if !entry(name, isDirectory, isHidden) { return true }
            }
        }
    }
}
