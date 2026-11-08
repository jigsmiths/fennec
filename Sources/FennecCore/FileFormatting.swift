import Foundation
import UniformTypeIdentifiers

public enum FileFormatting {
    public static func kind(for entry: FileEntry) -> String {
        if entry.isBrowsable { return "Folder" }
        if let description = entry.contentType?.localizedDescription, !description.isEmpty {
            return description
        }
        // Types macOS doesn't know (.go, .jsonl) have no description, so name them by extension.
        let ext = entry.url.pathExtension
        return ext.isEmpty ? "Document" : "\(ext.uppercased()) file"
    }

    public static func size(for entry: FileEntry) -> String {
        guard !entry.isBrowsable, let size = entry.size else { return "" }
        return bytes(size)
    }

    public static func bytes(_ count: Int64) -> String {
        sizeFormatter.string(fromByteCount: count)
    }

    // ByteCountFormatter is thread-safe for formatting once configured.
    nonisolated(unsafe) private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}
