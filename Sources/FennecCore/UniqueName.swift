import Foundation

/// Finder-style free names: "a.txt" becomes "a 2.txt", and "a 2.txt" becomes "a 3.txt".
public enum UniqueName {
    public static func available(for name: String, in directory: URL) -> URL {
        let first = directory.appendingPathComponent(name)
        if !FileItem.exists(first) { return first }

        let ext = (name as NSString).pathExtension
        var base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var number = 2
        if let range = base.range(of: #" \d+$"#, options: .regularExpression),
           let existing = Int(base[range].dropFirst()) {
            base = String(base[..<range.lowerBound])
            number = existing + 1
        }
        while true {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            if !FileItem.exists(candidate) { return candidate }
            number += 1
        }
    }
}

/// Small file-system queries shared by the operations code. Symlinks are not followed.
enum FileItem {
    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    /// Total bytes and number of files in an item, counting a folder's contents.
    static func measure(_ url: URL) -> (bytes: Int64, files: Int) {
        guard isDirectory(url) else {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return (size, 1)
        }
        var bytes: Int64 = 0
        var files = 0
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let child = enumerator?.nextObject() as? URL {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            bytes += Int64(values?.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let idA = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let idB = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let idA, let idB else { return false }
        return idA.isEqual(idB)
    }

    /// Moves or renames, including case-only renames, which FileManager rejects as "already exists".
    static func move(_ source: URL, to target: URL) throws {
        if source.path.lowercased() == target.path.lowercased() {
            guard Darwin.rename(source.path, target.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try FileManager.default.moveItem(at: source, to: target)
        }
    }
}
