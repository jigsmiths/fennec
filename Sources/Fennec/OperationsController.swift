import AppKit
import FennecCore

/// Runs file operations for one window: the job list, conflict questions, errors and undo.
@MainActor
final class OperationsController {
    /// A running copy or move. Progress and cancelling are touched from the background copy, so they're locked.
    final class Job: @unchecked Sendable, Identifiable {
        let id = UUID()
        let title: String
        private let lock = NSLock()
        private var latest: OperationProgress?
        private var cancelled = false

        init(title: String) {
            self.title = title
        }

        var progress: OperationProgress? { lock.withLock { latest } }
        var isCancelled: Bool { lock.withLock { cancelled } }
        func update(_ progress: OperationProgress) { lock.withLock { latest = progress } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    /// Called when jobs start or finish, and when one has run long enough to be worth showing.
    var onJobsChanged: (() -> Void)?
    /// Called with the items a finished operation created, so the folder can select them.
    var onPlaced: (([URL]) -> Void)?

    private(set) var visibleJobs: [Job] = []
    private weak var window: NSWindow?
    private let runner = FileOperationRunner()

    init(window: NSWindow?) {
        self.window = window
    }

    // MARK: Copy and move

    func transfer(_ sources: [URL], to destination: URL, mode: TransferMode) {
        guard !sources.isEmpty else { return }
        let job = Job(title: Self.title(for: sources, to: destination, mode: mode))
        let memory = ConflictMemory()
        showIfSlow(job)

        Task {
            do {
                let result = try await runner.transfer(
                    sources, to: destination, mode: mode,
                    onConflict: { conflict in
                        await self.ask(conflict, job: job, memory: memory)
                    },
                    progress: { job.update($0) },
                    isCancelled: { job.isCancelled })
                registerUndo(result.steps, name: mode == .copy ? "Copy" : "Move")
                onPlaced?(result.placed)
            } catch FileOperationError.cancelled {
            } catch {
                showError(error)
            }
            finish(job)
        }
    }

    private static func title(for sources: [URL], to destination: URL, mode: TransferMode) -> String {
        let verb = mode == .copy ? "Copying" : "Moving"
        let what = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(sources.count) items"
        return "\(verb) \(what) to “\(destination.lastPathComponent)”"
    }

    // Quick operations finish before anything is shown, so the toolbar doesn't flicker.
    private func showIfSlow(_ job: Job) {
        pending.insert(job.id)
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard pending.contains(job.id) else { return }
            visibleJobs.append(job)
            onJobsChanged?()
        }
    }

    private var pending: Set<UUID> = []

    private func finish(_ job: Job) {
        pending.remove(job.id)
        if visibleJobs.contains(where: { $0.id == job.id }) {
            visibleJobs.removeAll { $0.id == job.id }
            onJobsChanged?()
        }
    }

    // MARK: Conflicts

    /// Remembers "Apply to all" answers for one job, separately for files and folders.
    @MainActor
    private final class ConflictMemory {
        var forFiles: ConflictChoice?
        var forFolders: ConflictChoice?
    }

    private func ask(_ conflict: Conflict, job: Job, memory: ConflictMemory) async -> ConflictChoice {
        if let remembered = conflict.isFolder ? memory.forFolders : memory.forFiles { return remembered }
        guard let window else { return .skip }

        let name = conflict.existing.lastPathComponent
        let folder = conflict.existing.deletingLastPathComponent().lastPathComponent
        let alert = NSAlert()
        alert.messageText = "“\(name)” already exists in “\(folder)”."
        var choices: [ConflictChoice]
        if conflict.isFolder {
            alert.informativeText = "Merge combines both folders. You'll be asked about any file that exists in both."
            choices = [.merge, .keepBoth, .replace, .skip]
            ["Merge", "Keep Both", "Replace", "Skip"].forEach { alert.addButton(withTitle: $0) }
        } else {
            alert.informativeText = "Replace moves the existing item to the Trash."
            choices = [.keepBoth, .replace, .skip]
            ["Keep Both", "Replace", "Skip"].forEach { alert.addButton(withTitle: $0) }
        }
        alert.addButton(withTitle: "Stop")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all"

        let response = await alert.beginSheetModal(for: window)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0, index < choices.count else {
            job.cancel()
            return .skip
        }
        let choice = choices[index]
        if alert.suppressionButton?.state == .on {
            if conflict.isFolder { memory.forFolders = choice } else { memory.forFiles = choice }
        }
        return choice
    }

    // MARK: Trash, delete, rename, new folder

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let runner = runner
        Task {
            do {
                let steps = try await BlockingIO.run { try runner.trash(urls) }
                registerUndo(steps, name: "Move to Trash")
            } catch {
                showError(error)
            }
        }
    }

    func deleteImmediately(_ urls: [URL]) {
        guard !urls.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = urls.count == 1
            ? "Delete “\(urls[0].lastPathComponent)” immediately?"
            : "Delete \(urls.count) items immediately?"
        alert.informativeText = "This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        Task {
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            do {
                try await BlockingIO.run {
                    for url in urls { try FileManager.default.removeItem(at: url) }
                }
            } catch {
                showError(error)
            }
        }
    }

    /// Returns the renamed item's new location, or nil if nothing changed or it failed.
    func rename(_ url: URL, to name: String) async -> URL? {
        let runner = runner
        do {
            let renamed = try await BlockingIO.run { try runner.rename(url, to: name) }
            guard let step = renamed.step else { return nil }
            registerUndo([step], name: "Rename")
            return renamed.url
        } catch {
            showError(error)
            return nil
        }
    }

    func newFolder(in directory: URL) async -> URL? {
        let runner = runner
        do {
            let created = try await BlockingIO.run { try runner.createFolder(in: directory) }
            registerUndo([created.step], name: "New Folder")
            return created.url
        } catch {
            showError(error)
            return nil
        }
    }

    // MARK: Undo and errors

    private func registerUndo(_ steps: [UndoStep], name: String) {
        guard !steps.isEmpty, let undoManager = window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.undo(steps) }
        }
        undoManager.setActionName(name)
    }

    private func undo(_ steps: [UndoStep]) {
        let runner = runner
        Task {
            do {
                try await BlockingIO.run { try runner.undo(steps) }
            } catch {
                showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
