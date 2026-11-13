import CoreServices
import Foundation

/// Reports, on the main thread, which folders anywhere under a root had their contents change.
public final class TreeWatcher: @unchecked Sendable {
    /// Changed folders relative to the root ("" is the root). `everything` is true when FSEvents lost track
    /// and the whole tree must be treated as changed.
    public typealias Handler = @MainActor @Sendable (_ folders: [String], _ everything: Bool) -> Void

    private let rootPath: String
    private let onChange: Handler
    private var stream: FSEventStreamRef?

    public init(url: URL, onChange: @escaping Handler) {
        rootPath = Self.realPath(url.path)
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<TreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let eventPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var folders: [String] = []
            var everything = false
            for i in 0..<min(count, eventPaths.count) {
                let path = eventPaths[i]
                let mustScan = flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                let rootChanged = flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                if rootChanged || (mustScan && watcher.rootPath.hasPrefix(TreeWatcher.trimmed(path))) {
                    everything = true
                } else if let folder = TreeWatcher.relativeFolder(path, under: watcher.rootPath) {
                    folders.append(folder)
                }
            }
            if everything || !folders.isEmpty {
                MainActor.assumeIsolated { watcher.onChange(folders, everything) }
            }
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(
            nil, callback, &context, [rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// The event's folder relative to `root`, or nil when it's outside it. Both are real (resolved) paths.
    static func relativeFolder(_ eventPath: String, under root: String) -> String? {
        let path = trimmed(eventPath)
        let base = trimmed(root)
        if path == base { return "" }
        let prefix = base == "/" ? "/" : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // FSEvents reports resolved paths (e.g. /private/var), so compare against the same form.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
