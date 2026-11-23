import Foundation

/// Where each item Fennec trashed came from, so Put Back can return it. Finder keeps its own record,
/// but only in the Trash's .DS_Store, which needs Full Disk Access to read.
public final class TrashLedger: @unchecked Sendable {
    public static let shared = TrashLedger(
        file: URL.applicationSupportDirectory.appending(path: "Fennec/trash-ledger.json"))

    private let file: URL
    private let lock = NSLock()
    private var entries: [String: String]

    public init(file: URL) {
        self.file = file
        let data = try? Data(contentsOf: file)
        entries = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    public func record(original: URL, trashed: URL) {
        lock.withLock {
            entries[Self.key(trashed)] = Self.key(original)
            save()
        }
    }

    public func original(of trashed: URL) -> URL? {
        lock.withLock { entries[Self.key(trashed)].map { URL(filePath: $0) } }
    }

    /// Drops items that are no longer in the Trash: put back, deleted or emptied.
    public func prune() {
        lock.withLock {
            let kept = entries.filter { FileItem.exists(URL(filePath: $0.key)) }
            guard kept.count != entries.count else { return }
            entries = kept
            save()
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
