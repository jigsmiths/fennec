import Foundation
import FennecCore

@MainActor
final class FolderStatsService {
    static let shared = FolderStatsService()
    static let didUpdate = Notification.Name("FolderStatsService.didUpdate")
    static let activityDidChange = Notification.Name("FolderStatsService.activityDidChange")

    struct Scan {
        let url: URL
        let started: ContinuousClock.Instant
        let expectedFiles: Int64?
        var progress = FolderWalker.Progress(files: 0, bytes: 0, folder: "")

        var fraction: Double? { progress.fraction(ofExpected: expectedFiles) }
    }

    private struct Request {
        let url: URL
        let force: Bool
        var path: String { url.standardizedFileURL.path }
    }

    private static let walkQueue = DispatchQueue(label: "dev.bvdwalt.fennec.folder-stats", qos: .utility)
    private static let preemptAfter = Duration.seconds(1)
    private let store: FolderStatsStore?
    private var queue: [Request] = []
    private var isWorking = false
    private(set) var current: Scan?
    private var currentRequest: Request?
    private var currentFlag: CancelFlag?

    var queued: [URL] { queue.map(\.url) }

    private init() {
        store = try? FolderStatsStore()
    }

    func childStats(of folder: URL) async -> [String: FolderStats] {
        (try? await store?.childStats(of: folder)) ?? [:]
    }

    func request(_ folders: [URL]) {
        enqueue(folders, force: false)
    }

    func recalculate(_ folders: [URL]) {
        enqueue(folders, force: true)
    }

    func cancel(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        if currentRequest?.path == path { currentFlag?.set() }
        queue.removeAll { $0.path == path }
        postActivity()
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

        if let running = currentRequest, let scan = current, !paths.contains(running.path),
           scan.started.duration(to: .now) > Self.preemptAfter {
            queue.insert(running, at: requests.count)
            currentFlag?.set()
        }
        postActivity()
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
        let cached = try? await store.stats(for: request.url)
        if !request.force, cached != nil { return }

        let flag = CancelFlag()
        currentRequest = request
        currentFlag = flag
        current = Scan(url: request.url, started: .now, expectedFiles: cached?.files)
        postActivity()

        let url = request.url
        let force = request.force
        let walk = await withCheckedContinuation { continuation in
            Self.walkQueue.async {
                continuation.resume(returning: Self.walk(url, force: force, isCancelled: flag.get) { progress in
                    Task { @MainActor in self.update(progress, of: flag) }
                })
            }
        }

        currentRequest = nil
        currentFlag = nil
        current = nil
        postActivity()
        guard let walk else { return }
        try? await store.save(walk, at: url)
        NotificationCenter.default.post(name: Self.didUpdate, object: url)
    }

    private func update(_ progress: FolderWalker.Progress, of flag: CancelFlag) {
        guard currentFlag === flag else { return }
        current?.progress = progress
        postActivity()
    }

    private func postActivity() {
        NotificationCenter.default.post(name: Self.activityDidChange, object: self)
    }

    nonisolated private static func walk(
        _ url: URL, force: Bool, isCancelled: () -> Bool, progress: @escaping @Sendable (FolderWalker.Progress) -> Void
    ) -> FolderWalk? {
        if !force, (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false { return nil }
        return FolderWalker.walk(url, isCancelled: isCancelled, progress: progress)
    }
}
