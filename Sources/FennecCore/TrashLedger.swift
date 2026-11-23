import Foundation
import Synchronization

/// Where each item Fennec trashed came from, so Put Back can return it. Finder keeps its own record,
/// but only in the Trash's .DS_Store, which needs Full Disk Access to read.
public final class TrashLedger: Sendable {
    public static let shared = TrashLedger(
        file: URL.applicationSupportDirectory.appending(path: "Fennec/trash-ledger.json"))

    private let file: URL
    private let entries: Mutex<[String: String]>

    public init(file: URL) {
        self.file = file
        let data = try? Data(contentsOf: file)
        entries = Mutex(data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:])
    }

    public func record(original: URL, trashed: URL) {
        entries.withLock {
            $0[Self.key(trashed)] = Self.key(original)
            Self.save($0, to: file)
        }
    }

    public func original(of trashed: URL) -> URL? {
        entries.withLock { $0[Self.key(trashed)].map { URL(filePath: $0) } }
    }

    /// Drops items that are no longer in the Trash: put back, deleted or emptied.
    public func prune() {
        entries.withLock {
            let kept = $0.filter { FileItem.exists(URL(filePath: $0.key)) }
            guard kept.count != $0.count else { return }
            $0 = kept
            Self.save(kept, to: file)
        }
    }

    private static func save(_ entries: [String: String], to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
