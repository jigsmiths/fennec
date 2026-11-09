import Foundation

/// Copies, moves, trashes, renames and creates items. Every change is returned as undo steps.
public struct FileOperationRunner: Sendable {
    public struct Placed: Sendable {
        public let url: URL
        public let step: UndoStep
    }

    public struct Renamed: Sendable {
        public let url: URL
        /// Nil when the name didn't change.
        public let step: UndoStep?
    }

    private let trashItem: @Sendable (URL) throws -> URL

    /// `trash` is injectable so tests don't fill the real Trash.
    public init(trash: @escaping @Sendable (URL) throws -> URL = FileOperationRunner.systemTrash) {
        trashItem = trash
    }

    public static func systemTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    // MARK: Copy and move

    /// `forceCopy` makes a same-disk move take the copy, verify, delete path, as between disks.
    public func transfer(
        _ sources: [URL], to destination: URL, mode: TransferMode, forceCopy: Bool = false,
        onConflict: @escaping ConflictHandler,
        progress: @escaping @Sendable (OperationProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> TransferResult {
        let totals = try await BlockingIO.run {
            sources.reduce(into: (bytes: Int64(0), files: 0)) { sum, url in
                let size = FileItem.measure(url)
                sum.bytes += size.bytes
                sum.files += size.files
            }
        }
        let tracker = ProgressTracker(totalBytes: totals.bytes, totalItems: totals.files, report: progress)
        let job = Job(mode: mode, forceCopy: forceCopy, onConflict: onConflict, tracker: tracker, isCancelled: isCancelled)

        var result = TransferResult()
        for source in sources {
            if let placed = try await transferItem(source, into: destination, job: job, result: &result) {
                result.placed.append(placed)
            }
        }
        tracker.finishAll()
        return result
    }

    private struct Job: Sendable {
        let mode: TransferMode
        let forceCopy: Bool
        let onConflict: ConflictHandler
        let tracker: ProgressTracker
        let isCancelled: @Sendable () -> Bool

        func checkCancelled() throws {
            if isCancelled() || Task.isCancelled { throw FileOperationError.cancelled }
        }
    }

    private func transferItem(
        _ source: URL, into destination: URL, job: Job, result: inout TransferResult
    ) async throws -> URL? {
        try job.checkCancelled()
        let name = source.lastPathComponent
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
            throw FileOperationError.intoItself(name)
        }

        let size = try await BlockingIO.run { FileItem.measure(source) }
        job.tracker.startItem(name: name, bytes: size.bytes, files: size.files)
        var target = destination.appendingPathComponent(name)

        if source.deletingLastPathComponent().standardizedFileURL.path == destinationPath {
            // Moving into its own folder changes nothing; copying there makes "name 2", like Finder.
            if job.mode == .move {
                job.tracker.finishItem()
                return source
            }
            target = UniqueName.available(for: name, in: destination)
        } else if FileItem.exists(target) {
            let isFolder = FileItem.isDirectory(source) && FileItem.isDirectory(target)
            switch await job.onConflict(Conflict(source: source, existing: target, isFolder: isFolder)) {
            case .skip:
                job.tracker.finishItem()
                return nil
            case .keepBoth:
                target = UniqueName.available(for: name, in: destination)
            case .replace:
                let existing = target
                let trashed = try await BlockingIO.run { try trashItem(existing) }
                result.steps.append(.trashed(original: existing, trashed: trashed))
            case .merge where isFolder:
                try await merge(source, into: target, job: job, result: &result)
                return target
            case .merge:
                target = UniqueName.available(for: name, in: destination)
            }
        }

        try job.checkCancelled()
        let finalTarget = target
        if job.mode == .move, !job.forceCopy, FileItem.sameVolume(source, destination) {
            try await BlockingIO.run { try FileItem.move(source, to: finalTarget) }
            result.steps.append(.moved(from: source, to: finalTarget))
        } else {
            try await BlockingIO.run {
                try CopyFile.copy(source, to: finalTarget, tracker: job.tracker, isCancelled: job.isCancelled)
            }
            if job.mode == .move {
                try await BlockingIO.run {
                    // Only delete the original once the copy is known to be complete.
                    let copied = FileItem.measure(finalTarget)
                    guard copied.bytes == size.bytes, copied.files == size.files else {
                        try? FileManager.default.removeItem(at: finalTarget)
                        throw FileOperationError.verificationFailed(name)
                    }
                    try FileManager.default.removeItem(at: source)
                }
                result.steps.append(.moved(from: source, to: finalTarget))
            } else {
                result.steps.append(.created(finalTarget))
            }
        }
        job.tracker.finishItem()
        return finalTarget
    }

    private func merge(_ source: URL, into target: URL, job: Job, result: inout TransferResult) async throws {
        job.tracker.finishItem()
        let children = try await BlockingIO.run {
            try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        }
        for child in children {
            _ = try await transferItem(child, into: target, job: job, result: &result)
        }
        guard job.mode == .move else { return }
        let removed = try await BlockingIO.run {
            // Items skipped during the merge stay behind, and so does their folder.
            guard try FileManager.default.contentsOfDirectory(atPath: source.path).isEmpty else { return false }
            try FileManager.default.removeItem(at: source)
            return true
        }
        if removed { result.steps.append(.removedFolder(source)) }
    }

    // MARK: Trash, rename, new folder

    public func trash(_ urls: [URL]) throws -> [UndoStep] {
        try urls.map { url in .trashed(original: url, trashed: try trashItem(url)) }
    }

    public func rename(_ url: URL, to newName: String) throws -> Renamed {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":") else {
            throw FileOperationError.invalidName(newName)
        }
        if name == url.lastPathComponent { return Renamed(url: url, step: nil) }

        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        let caseOnly = name.lowercased() == url.lastPathComponent.lowercased()
        if !caseOnly, FileItem.exists(target) { throw FileOperationError.alreadyExists(name) }
        try FileItem.move(url, to: target)
        return Renamed(url: target, step: .moved(from: url, to: target))
    }

    public func createFolder(in directory: URL, named name: String = "untitled folder") throws -> Placed {
        let url = UniqueName.available(for: name, in: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return Placed(url: url, step: .created(url))
    }

    // MARK: Undo

    /// Reverses the steps, newest first. Created items go to the Trash rather than being deleted.
    public func undo(_ steps: [UndoStep]) throws {
        for step in steps.reversed() {
            switch step {
            case .created(let url):
                _ = try trashItem(url)
            case .moved(let from, let to):
                try FileManager.default.createDirectory(
                    at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileItem.move(to, to: from)
            case .trashed(let original, let trashed):
                try FileItem.move(trashed, to: original)
            case .removedFolder(let url):
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }
}

/// Byte and item counts for one transfer, reported as files are copied.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: OperationProgress
    private var itemBaseBytes: Int64 = 0
    private var itemBytes: Int64 = 0
    private var itemBaseFiles = 0
    private var itemFiles = 0
    private var finishedFileBytes: Int64 = 0
    private let report: @Sendable (OperationProgress) -> Void

    init(totalBytes: Int64, totalItems: Int, report: @escaping @Sendable (OperationProgress) -> Void) {
        progress = OperationProgress(
            completedBytes: 0, totalBytes: totalBytes, completedItems: 0, totalItems: totalItems, currentName: "")
        self.report = report
    }

    func startItem(name: String, bytes: Int64, files: Int) {
        update {
            itemBaseBytes = progress.completedBytes
            itemBaseFiles = progress.completedItems
            itemBytes = bytes
            itemFiles = files
            finishedFileBytes = 0
            progress.currentName = name
        }
    }

    /// Bytes copied so far of the file currently being copied.
    func fileProgress(_ copied: Int64) {
        update { progress.completedBytes = min(itemBaseBytes + finishedFileBytes + copied, itemBaseBytes + itemBytes) }
    }

    func fileFinished(size: Int64) {
        update {
            finishedFileBytes += size
            progress.completedBytes = min(itemBaseBytes + finishedFileBytes, itemBaseBytes + itemBytes)
            progress.completedItems = min(progress.completedItems + 1, itemBaseFiles + itemFiles)
        }
    }

    /// Clones and skipped items never report per-file progress, so line the totals up per item.
    func finishItem() {
        update {
            progress.completedBytes = itemBaseBytes + itemBytes
            progress.completedItems = itemBaseFiles + itemFiles
        }
    }

    func finishAll() {
        update {
            progress.completedBytes = progress.totalBytes
            progress.completedItems = progress.totalItems
        }
    }

    private func update(_ change: () -> Void) {
        let snapshot = lock.withLock {
            change()
            return progress
        }
        report(snapshot)
    }
}
