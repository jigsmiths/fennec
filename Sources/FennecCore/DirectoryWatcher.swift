import CoreServices
import Foundation

/// Calls `onChange` on the main thread when the watched folder's own contents change.
public final class DirectoryWatcher: @unchecked Sendable {
    private let watchedPath: String
    private let onChange: @MainActor @Sendable () -> Void
    private var stream: FSEventStreamRef?

    public init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        watchedPath = Self.realPath(url.path)
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let eventPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let relevant = (0..<count).contains { i in
                watcher.affectsWatchedFolder(eventPaths[i], flags: flags[i])
            }
            if relevant {
                MainActor.assumeIsolated { watcher.onChange() }
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(
            nil, callback, &context, [watchedPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags)
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

    private func affectsWatchedFolder(_ eventPath: String, flags: FSEventStreamEventFlags) -> Bool {
        let path = eventPath.hasSuffix("/") && eventPath.count > 1 ? String(eventPath.dropLast()) : eventPath
        if path == watchedPath { return true }
        let mustScan = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
        return mustScan && watchedPath.hasPrefix(path)
    }

    // FSEvents reports resolved paths (e.g. /private/var), so compare against the same form.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
