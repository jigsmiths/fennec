import AppKit
import FennecCore
import Synchronization

@MainActor
final class OperationsController {
    final class Job: Sendable, Identifiable {
        let id = UUID()
        let title: String
        private let latest = Mutex<OperationProgress?>(nil)
        private let cancelled = Atomic(false)

        init(title: String) {
            self.title = title
        }

        var progress: OperationProgress? { latest.withLock { $0 } }
        var isCancelled: Bool { cancelled.load(ordering: .acquiring) }
        func update(_ progress: OperationProgress) { latest.withLock { $0 = progress } }
        func cancel() { cancelled.store(true, ordering: .releasing) }
    }

    var onJobsChanged: (() -> Void)?
    var onPlaced: (([URL]) -> Void)?

    private(set) var visibleJobs: [Job] = []
    private weak var window: NSWindow?
    private let runner = FileOperationRunner()

    init(window: NSWindow?) {
        self.window = window
    }

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
                rememberTrashed(result.steps)
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

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let runner = runner
        Task {
            do {
                let steps = try await BlockingIO.run { try runner.trash(urls) }
                rememberTrashed(steps)
                registerUndo(steps, name: "Move to Trash")
            } catch {
                showError(error)
            }
        }
    }

    private func rememberTrashed(_ steps: [UndoStep]) {
        for case .trashed(let original, let trashed) in steps {
            TrashLedger.shared.record(original: original, trashed: trashed)
        }
    }

    func putBack(_ urls: [URL]) {
        let items = urls.compactMap { url in TrashLedger.shared.original(of: url).map { (trashed: url, original: $0) } }
        guard !items.isEmpty else { return }
        let runner = runner
        Task {
            do {
                let steps = try await BlockingIO.run { try runner.putBack(items) }
                registerUndo(steps, name: "Put Back")
                onPlaced?(items.map(\.original))
            } catch {
                showError(error)
            }
        }
    }

    func emptyTrash() {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Permanently erase the items in the Trash?"
        alert.informativeText = "This can't be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        Task {
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            do {
                try await BlockingIO.run {
                    try FinderTrash.empty()
                    TrashLedger.shared.prune()
                }
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
