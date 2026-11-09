import Darwin
import Foundation

/// Wraps copyfile(3): clones on APFS when it can, keeps all metadata, reports progress and can be cancelled.
enum CopyFile {
    private final class Context {
        let tracker: ProgressTracker
        let isCancelled: @Sendable () -> Bool
        var currentFileBytes: Int64 = 0

        init(tracker: ProgressTracker, isCancelled: @escaping @Sendable () -> Bool) {
            self.tracker = tracker
            self.isCancelled = isCancelled
        }
    }

    static func copy(
        _ source: URL, to target: URL, tracker: ProgressTracker, isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        let context = Context(tracker: tracker, isCancelled: isCancelled)
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }

        let callback: copyfile_callback_t = { what, stage, state, _, _, info in
            guard let info else { return COPYFILE_CONTINUE }
            let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                context.currentFileBytes = Int64(copied)
                context.tracker.fileProgress(Int64(copied))
            } else if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH {
                context.tracker.fileFinished(size: context.currentFileBytes)
                context.currentFileBytes = 0
            }
            return context.isCancelled() ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }

        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())

        if isCancelled() { throw FileOperationError.cancelled }
        let flags = copyfile_flags_t(
            COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA
                | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_EXCL)
        let status = withExtendedLifetime(context) {
            copyfile(source.path, target.path, state, flags)
        }
        guard status == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: target)
            if code == ECANCELED || isCancelled() { throw FileOperationError.cancelled }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
