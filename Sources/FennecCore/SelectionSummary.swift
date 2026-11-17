import Foundation

public enum SelectionSummary {
    /// Describes a multi-item selection, e.g. "3 items (1 folder), 4 KB". Folders count toward the size only once
    /// their stats are known, and a selection of folders with none known shows no size at all.
    public static func describe(_ entries: [FileEntry]) -> String {
        let folders = entries.filter(\.isBrowsable).count
        let files = entries.count - folders
        let sizes = entries.compactMap(\.displaySize)
        let folderCount = "\(folders) folder\(folders == 1 ? "" : "s")"
        if files == 0, sizes.isEmpty { return folderCount }

        var count = files == 0 ? folderCount : "\(entries.count) item\(entries.count == 1 ? "" : "s")"
        if files > 0, folders > 0 { count += " (\(folderCount))" }
        return "\(count), \(FileFormatting.bytes(sizes.reduce(0, +)))"
    }
}
