import Foundation
import FennecCore

@MainActor
final class FinderIndex {
    static let limit = 500_000
    private static let batchSize = 1_000

    let root: URL
    let includeHidden: Bool
    private(set) var items: [FileIndexer.Item] = []
    private(set) var candidates: [FuzzyMatcher.Candidate] = []
    private(set) var version = 0
    private(set) var isWalking = false
    private(set) var hasWalked = false

    private static let refreshCooldown: Duration = .seconds(5)

    private var listeners: [UUID: () -> Void] = [:]
    private var isStale = true
    private var lastWalkEnded: ContinuousClock.Instant?
    private var refreshScheduled = false
    private var folders: Set<String> = [""]
    private var watcher: TreeWatcher?
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
            return folders.contains(relative) && !reachedLimit ? relative : nil
        }
        return FileIndexer.listsFolder(relative, includeHidden: includeHidden) ? relative : nil
    }

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

    func refreshIfNeeded(priority: TaskPriority = .userInitiated) {
        guard isStale, !isWalking else { return }
        isStale = false
        isWalking = true
        if watcher == nil {
            watcher = TreeWatcher(url: root) { [weak self] folders, everything in
                self?.treeChanged(folders, everything: everything)
            }
        }

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
