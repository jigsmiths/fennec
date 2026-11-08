import Foundation

public enum SelectionSummary {
    /// Describes a multi-item selection, e.g. "3 items (1 folder), 4 KB". Folder sizes aren't known, so only files count.
    public static func describe(_ entries: [FileEntry]) -> String {
        let folders = entries.filter(\.isBrowsable).count
        let files = entries.count - folders
        if files == 0 { return "\(folders) folder\(folders == 1 ? "" : "s")" }

        var count = "\(entries.count) item\(entries.count == 1 ? "" : "s")"
        if folders > 0 { count += " (\(folders) folder\(folders == 1 ? "" : "s"))" }
        let bytes = entries.filter { !$0.isBrowsable }.compactMap(\.size).reduce(0, +)
        return "\(count), \(FileFormatting.bytes(bytes))"
    }
}
