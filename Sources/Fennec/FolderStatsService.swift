import Foundation
import FennecCore

/// Works out folder stats in the background, one walk at a time, and keeps them in the shared cache.
/// The latest requests go first, so the folder being looked at isn't stuck behind ones already left.
@MainActor
final class FolderStatsService {
    static let shared = FolderStatsService()
    /// Posted after a walk is saved, with the walked folder's URL as the object.
    static let didUpdate = Notification.Name("FolderStatsService.didUpdate")

    private struct Request {
        let url: URL
        let force: Bool
        var path: String { url.standardizedFileURL.path }
    }

    private static let walkQueue = DispatchQueue(label: "dev.bvdwalt.fennec.folder-stats", qos: .utility)
    /// Nil when the cache can't be opened, which turns folder stats off rather than failing loads.
    private let store: FolderStatsStore?
    private var queue: [Request] = []
    private var isWorking = false

    private init() {
        store = try? FolderStatsStore()
    }

    func childStats(of folder: URL) async -> [String: FolderStats] {
        (try? await store?.childStats(of: folder)) ?? [:]
    }

    /// Queues folders to be walked if they still have no stats by the time their turn comes.
    func request(_ folders: [URL]) {
        enqueue(folders, force: false)
    }

    /// Walks folders again even if they have stats, and even on network volumes.
    func recalculate(_ folders: [URL]) {
        enqueue(folders, force: true)
    }

    private func enqueue(_ folders: [URL], force: Bool) {
        guard store != nil, !folders.isEmpty else { return }
        let requests = folders.map { Request(url: $0, force: force) }
        let paths = Set(requests.map(\.path))
        let alreadyForced = Set(queue.filter { $0.force && paths.contains($0.path) }.map(\.path))
        queue.removeAll { paths.contains($0.path) }
        queue.insert(contentsOf: requests.map {
            Request(url: $0.url, force: $0.force || alreadyForced.contains($0.path))
        }, at: 0)
        work()
    }

    private func work() {
        guard !isWorking, let store else { return }
        isWorking = true
        Task {
            while !queue.isEmpty {
                await process(queue.removeFirst(), store)
            }
            isWorking = false
        }
    }

    private func process(_ request: Request, _ store: FolderStatsStore) async {
        // A walk of a folder above this one may have covered it while it waited.
        if !request.force, (try? await store.stats(for: request.url)) != nil { return }
        let url = request.url
        let force = request.force
        let walk = await withCheckedContinuation { continuation in
            Self.walkQueue.async { continuation.resume(returning: Self.walk(url, force: force)) }
        }
        guard let walk else { return }
        try? await store.save(walk, at: url)
        NotificationCenter.default.post(name: Self.didUpdate, object: url)
    }

    /// Network volumes are only walked when asked for, since a big share could take hours.
    nonisolated private static func walk(_ url: URL, force: Bool) -> FolderWalk? {
        if !force, (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false { return nil }
        return FolderWalker.walk(url)
    }
}
