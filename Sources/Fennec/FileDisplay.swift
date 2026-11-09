import AppKit
import FennecCore
import UniformTypeIdentifiers

/// Icons, kinds and formatted values, cached per file type so scrolling never hits Launch Services twice.
@MainActor
enum FileDisplay {
    private static var iconsByType: [String: NSImage] = [:]
    private static var iconsByPath: [String: NSImage] = [:]
    private static var kindsByType: [String: String] = [:]
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func icon(for entry: FileEntry) -> NSImage {
        if entry.isPackage {
            if let cached = iconsByPath[entry.path] { return cached }
            let icon = NSWorkspace.shared.icon(forFile: entry.path)
            iconsByPath[entry.path] = icon
            return icon
        }
        if entry.isBrowsable { return folderIcon }
        let type = entry.typeIdentifier ?? UTType.data.identifier
        if let cached = iconsByType[type] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(type) ?? .data)
        iconsByType[type] = icon
        return icon
    }

    static func kind(for entry: FileEntry) -> String {
        guard !entry.isBrowsable, let type = entry.typeIdentifier else { return FileFormatting.kind(for: entry) }
        if let cached = kindsByType[type] { return cached }
        let kind = FileFormatting.kind(for: entry)
        kindsByType[type] = kind
        return kind
    }

    static func date(_ date: Date?) -> String {
        date.map(dateFormatter.string(from:)) ?? ""
    }
}
