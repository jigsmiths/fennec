import CoreServices
import Foundation

/// Calls `onChange` on the main thread when the watched folder's own contents change.
public final class DirectoryWatcher {
    private let stream: FSEventStreamRef?

    public init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        let handler = Handler(watchedPath: Self.realPath(url.path), onChange: onChange)
        var context = FSEventStreamContext.retaining(handler)

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let eventPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let relevant = (0..<count).contains { i in
                handler.affectsWatchedFolder(eventPaths[i], flags: flags[i])
            }
            if relevant {
                MainActor.assumeIsolated { handler.onChange() }
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(
            nil, callback, &context, [handler.watchedPath] as CFArray,
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

    private final class Handler: Sendable {
        let watchedPath: String
        let onChange: @MainActor @Sendable () -> Void

        init(watchedPath: String, onChange: @escaping @MainActor @Sendable () -> Void) {
            self.watchedPath = watchedPath
            self.onChange = onChange
        }

        func affectsWatchedFolder(_ eventPath: String, flags: FSEventStreamEventFlags) -> Bool {
            let path = eventPath.hasSuffix("/") && eventPath.count > 1 ? String(eventPath.dropLast()) : eventPath
            if path == watchedPath { return true }
            let mustScan = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            return mustScan && watchedPath.hasPrefix(path)
        }
    }

    // FSEvents reports resolved paths (e.g. /private/var), so compare against the same form.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
