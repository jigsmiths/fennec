import Foundation
import Synchronization
import UniformTypeIdentifiers

public enum FileFormatting {
    public static func kind(for entry: FileEntry) -> String {
        if entry.isBrowsable { return "Folder" }
        if let description = entry.contentType?.localizedDescription, !description.isEmpty {
            return description
        }
        let ext = entry.url.pathExtension
        return ext.isEmpty ? "Document" : "\(ext.uppercased()) file"
    }

    public static func size(for entry: FileEntry) -> String {
        entry.displaySize.map(bytes) ?? ""
    }

    /// The Size column's tooltip for a folder, e.g. "1,204 files in 37 folders / 52 MB on disk / Calculated 2 hours ago".
    public static func folderStatsDetail(_ stats: FolderStats, now: Date = Date()) -> String {
        var lines = [
            "\(count(stats.files, "file")) in \(count(stats.subfolders, "folder"))",
            "\(bytes(stats.allocated)) on disk",
        ]
        if stats.incomplete { lines.append("Some folders inside couldn't be read") }
        let calculated = relativeFormatter.withLock { $0.localizedString(for: stats.calculated, relativeTo: now) }
        lines.append("Calculated \(calculated)")
        return lines.joined(separator: "\n")
    }

    private static func count(_ value: Int64, _ noun: String) -> String {
        "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")"
    }

    private static let relativeFormatter = Mutex(RelativeDateTimeFormatter())

    public static func bytes(_ count: Int64) -> String {
        sizeFormatter.withLock { $0.string(fromByteCount: count) }
    }

    private static let sizeFormatter: Mutex<ByteCountFormatter> = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return Mutex(formatter)
    }()
}
