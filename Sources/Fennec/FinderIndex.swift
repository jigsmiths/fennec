import Foundation
import FennecCore

/// Everything under one folder, kept between Find sessions so reopening is instant. Watches the tree and only
/// walks it again, in the background, after a folder it listed has changed. One index can serve several
/// windows, and searches in any folder it covers.
@MainActor
final class FinderIndex {
    // About 550 bytes per item, so roughly 275 MB at the cap.
    static let limit = 500_000
    private static let batchSize = 1_000

    let root: URL
    let includeHidden: Bool
    private(set) var items: [FileIndexer.Item] = []
    /// Parallel to `items`, so searches don't map over them on every keystroke.
    private(set) var candidates: [FuzzyMatcher.Candidate] = []
    /// Bumped when the items are replaced rather than appended to, so a search can't narrow across a refresh.
    private(set) var version = 0
    /// A walk is running; when `items` isn't empty it's refreshing them and they stay usable until it ends.
    private(set) var isWalking = false
    /// A walk has finished, so `items` is complete (if perhaps out of date).
    private(set) var hasWalked = false

    /// While a panel is open, a folder that keeps changing (build output, say) must not re-walk back to back.
    private static let refreshCooldown: Duration = .seconds(5)

    /// Open Find panels showing this index, told when items are added or replaced.
    private var listeners: [UUID: () -> Void] = [:]
    private var isStale = true
    private var lastWalkEnded: ContinuousClock.Instant?
    private var refreshScheduled = false
    /// The folders the walk listed, relative to root; a change in any other folder can't affect the index.
    private var folders: Set<String> = [""]
    private var watcher: TreeWatcher?
    /// The last scope worked out, extended as items stream in rather than recomputed per search.
    private var scopeCache: (folder: String, version: Int, scanned: Int, indices: [Int])?

    init(root: URL, includeHidden: Bool) {
        self.root = root
        self.includeHidden = includeHidden
    }

    var reachedLimit: Bool { items.count >= Self.limit }

    func addListener(_ listener: @escaping () -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    // MARK: Covering folders

    /// `folder`'s path relative to root when this index holds everything under it, else nil.
    func relativePath(of folder: URL, includeHidden: Bool) -> String? {
        guard includeHidden == self.includeHidden else { return nil }
        let path = Self.normalized(folder), rootPath = Self.normalized(root)
        let relative: String
        if path == rootPath {
            relative = ""
        } else if path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") {
            relative = String(path.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1))
        } else {
            return nil
        }
        if relative.isEmpty { return "" }
        if hasWalked {
            // A subfolder may have been cut off by the limit, so only trust a complete walk.
            return folders.contains(relative) && !reachedLimit ? relative : nil
        }
        // Mid-walk: the walk will list it unless it's hidden or skipped.
        let components = relative.split(separator: "/")
        return components.contains { $0.hasPrefix(".") || $0 == "node_modules" } ? nil : relative
    }

    /// The search scope for a folder from `relativePath(of:)`; nil means the whole index.
    func scope(forRelativePath folder: String) -> FuzzyMatcher.Scope? {
        guard !folder.isEmpty else { return nil }
        var indices: [Int] = []
        var start = 0
        if let cache = scopeCache, cache.folder == folder, cache.version == version, cache.scanned <= candidates.count {
            indices = cache.indices
            start = cache.scanned
        }
        let prefix = folder + "/"
        for index in start..<candidates.count where candidates[index].text.hasPrefix(prefix) {
            indices.append(index)
        }
        scopeCache = (folder, version, candidates.count, indices)
        return FuzzyMatcher.Scope(indices: indices, skip: prefix.utf16.count)
    }

    private static func normalized(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: Walking

    /// Walks the tree if nothing is indexed yet or something changed since the last walk.
    func refreshIfNeeded(priority: TaskPriority = .userInitiated) {
        guard isStale, !isWalking else { return }
        isStale = false
        isWalking = true
        if watcher == nil {
            watcher = TreeWatcher(url: root) { [weak self] folders, everything in
                self?.treeChanged(folders, everything: everything)
            }
        }

        // The first walk streams in; a refresh builds aside and swaps in at the end.
        let replacing = hasWalked
        let root = root, includeHidden = includeHidden, limit = Self.limit, batchSize = Self.batchSize
        let batches = AsyncStream<[FileIndexer.Item]> { continuation in
            let walk = Task.detached(priority: priority) {
                FileIndexer.walk(root, includeHidden: includeHidden, limit: limit,
                                 batchSize: batchSize) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in walk.cancel() }
        }
        Task { [weak self] in
            var freshItems: [FileIndexer.Item] = []
            var freshFolders: Set<String> = [""]
            for await batch in batches {
                // Leaving the loop ends the stream, which cancels the walk.
                guard let self else { return }
                let newFolders = batch.lazy.filter(\.isBrowsable).map(\.relativePath)
                if replacing {
                    freshItems += batch
                    freshFolders.formUnion(newFolders)
                } else {
                    self.items += batch
                    self.candidates += batch.map(\.candidate)
                    self.folders.formUnion(newFolders)
                    self.notify()
                }
            }
            guard let self else { return }
            if replacing {
                self.items = freshItems
                self.candidates = freshItems.map(\.candidate)
                self.folders = freshFolders
                self.version += 1
            }
            self.isWalking = false
            self.hasWalked = true
            self.lastWalkEnded = .now
            self.notify()
            // Something changed during the walk; catch up if a panel is still showing results.
            if self.isStale { self.refreshWhileShown() }
        }
    }

    private func notify() {
        for listener in listeners.values { listener() }
    }

    private func treeChanged(_ changed: [String], everything: Bool) {
        guard !isStale else { return }
        guard everything || changed.contains(where: folders.contains) else { return }
        isStale = true
        refreshWhileShown()
    }

    /// Refreshes now if a panel is open, after the cooldown; otherwise the next Find refreshes.
    private func refreshWhileShown() {
        guard !listeners.isEmpty, !isWalking, !refreshScheduled else { return }
        refreshScheduled = true
        let wait = lastWalkEnded.map { Self.refreshCooldown - (ContinuousClock.now - $0) } ?? .zero
        Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard let self else { return }
            self.refreshScheduled = false
            if !self.listeners.isEmpty { self.refreshIfNeeded() }
        }
    }
}
