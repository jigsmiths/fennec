import Foundation
import Testing
@testable import FennecCore

/// A runner whose "Trash" is a temp folder, so tests never touch the real Trash.
private func makeRunner(_ root: TempDir) throws -> FileOperationRunner {
    let trash = root.url.appendingPathComponent(".test-trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    return FileOperationRunner(trash: { url in
        let target = UniqueName.available(for: url.lastPathComponent, in: trash)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    })
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

private let neverCalled: ConflictHandler = { _ in
    Issue.record("unexpected conflict")
    return .skip
}

struct UniqueNameTests {
    @Test func addsNumberBeforeExtension() throws {
        let dir = try TempDir()
        try dir.file("a.txt")
        #expect(UniqueName.available(for: "a.txt", in: dir.url).lastPathComponent == "a 2.txt")
    }

    @Test func continuesFromAnExistingNumber() throws {
        let dir = try TempDir()
        try dir.file("a 2.txt")
        #expect(UniqueName.available(for: "a 2.txt", in: dir.url).lastPathComponent == "a 3.txt")
    }

    @Test func handlesFoldersAndDotfiles() throws {
        let dir = try TempDir()
        try dir.folder("untitled folder")
        try dir.file(".env")
        #expect(UniqueName.available(for: "untitled folder", in: dir.url).lastPathComponent == "untitled folder 2")
        #expect(UniqueName.available(for: ".env", in: dir.url).lastPathComponent == ".env 2")
    }

    @Test func freeNameIsKept() throws {
        let dir = try TempDir()
        #expect(UniqueName.available(for: "b.txt", in: dir.url).lastPathComponent == "b.txt")
    }
}

struct TransferTests {
    @Test func copyKeepsSourceAndCopiesFolders() async throws {
        let root = try TempDir()
        let src = root.url.appendingPathComponent("src/Photos", isDirectory: true)
        try write("one", to: src.appendingPathComponent("a.txt"))
        let dest = root.url.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        _ = try await makeRunner(root).transfer([src], to: dest, mode: .copy, onConflict: neverCalled)

        #expect(exists(src.appendingPathComponent("a.txt")))
        #expect(try read(dest.appendingPathComponent("Photos/a.txt")) == "one")
    }

    @Test func copyIntoSameFolderKeepsBoth() async throws {
        let root = try TempDir()
        let file = root.url.appendingPathComponent("a.txt")
        try write("one", to: file)

        _ = try await makeRunner(root).transfer([file], to: root.url, mode: .copy, onConflict: neverCalled)

        #expect(try read(root.url.appendingPathComponent("a 2.txt")) == "one")
    }

    @Test(arguments: [false, true])
    func moveRemovesSource(forceCopy: Bool) async throws {
        let root = try TempDir()
        let file = root.url.appendingPathComponent("src/a.txt")
        try write("one", to: file)
        let dest = root.url.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        _ = try await makeRunner(root).transfer(
            [file], to: dest, mode: .move, forceCopy: forceCopy, onConflict: neverCalled)

        #expect(!exists(file))
        #expect(try read(dest.appendingPathComponent("a.txt")) == "one")
    }

    @Test func movingIntoItselfFails() async throws {
        let root = try TempDir()
        let folder = root.url.appendingPathComponent("Folder", isDirectory: true)
        let inner = folder.appendingPathComponent("Inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        await #expect(throws: FileOperationError.self) {
            try await makeRunner(root).transfer([folder], to: inner, mode: .move, onConflict: neverCalled)
        }
        #expect(exists(inner))
    }

    @Test func fileConflictChoices() async throws {
        for (choice, expected) in [(ConflictChoice.skip, "old"), (.replace, "new"), (.keepBoth, "old")] {
            let root = try TempDir()
            let source = root.url.appendingPathComponent("src/a.txt")
            try write("new", to: source)
            let existing = root.url.appendingPathComponent("dest/a.txt")
            try write("old", to: existing)

            _ = try await makeRunner(root).transfer(
                [source], to: existing.deletingLastPathComponent(), mode: .copy, onConflict: { _ in choice })

            #expect(try read(existing) == expected, "choice \(choice)")
            if choice == .keepBoth {
                #expect(try read(root.url.appendingPathComponent("dest/a 2.txt")) == "new")
            }
        }
    }

    @Test func mergeCombinesFolderContents() async throws {
        let root = try TempDir()
        try write("dest a", to: root.url.appendingPathComponent("dest/F/a.txt"))
        try write("src a", to: root.url.appendingPathComponent("src/F/a.txt"))
        try write("src b", to: root.url.appendingPathComponent("src/F/b.txt"))
        let seen = CallCounter()

        _ = try await makeRunner(root).transfer(
            [root.url.appendingPathComponent("src/F")], to: root.url.appendingPathComponent("dest"),
            mode: .move,
            onConflict: { conflict in
                seen.increment()
                return conflict.isFolder ? .merge : .skip
            })

        #expect(seen.value == 2)
        #expect(try read(root.url.appendingPathComponent("dest/F/a.txt")) == "dest a")
        #expect(try read(root.url.appendingPathComponent("dest/F/b.txt")) == "src b")
        // The skipped a.txt stays behind, so the source folder is kept.
        #expect(exists(root.url.appendingPathComponent("src/F/a.txt")))
    }

    @Test func cancelLeavesNoPartialCopy() async throws {
        let root = try TempDir()
        let file = root.url.appendingPathComponent("src/a.txt")
        try write("one", to: file)
        let dest = root.url.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        await #expect(throws: FileOperationError.cancelled) {
            try await makeRunner(root).transfer(
                [file], to: dest, mode: .copy, onConflict: neverCalled, isCancelled: { true })
        }
        #expect(!exists(dest.appendingPathComponent("a.txt")))
        #expect(exists(file))
    }

    @Test func progressReachesTotal() async throws {
        let root = try TempDir()
        let file = root.url.appendingPathComponent("src/big.bin")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1_000_000).write(to: file)
        let dest = root.url.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let last = LastProgress()

        _ = try await makeRunner(root).transfer(
            [file], to: dest, mode: .copy, forceCopy: true, onConflict: neverCalled,
            progress: { last.set($0) })

        #expect(last.value?.totalBytes == 1_000_000)
        #expect(last.value?.completedBytes == 1_000_000)
    }
}

struct TrashRenameUndoTests {
    @Test func undoCopyRemovesTheCopies() async throws {
        let root = try TempDir()
        let file = root.url.appendingPathComponent("src/a.txt")
        try write("one", to: file)
        let dest = root.url.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let runner = try makeRunner(root)

        let result = try await runner.transfer([file], to: dest, mode: .copy, onConflict: neverCalled)
        try runner.undo(result.steps)

        #expect(!exists(dest.appendingPathComponent("a.txt")))
        #expect(exists(file))
    }

    @Test func undoMovePutsItemsBack() async throws {
        let root = try TempDir()
        let file = root.url.appendingPathComponent("src/a.txt")
        try write("one", to: file)
        let dest = root.url.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let runner = try makeRunner(root)

        let result = try await runner.transfer([file], to: dest, mode: .move, onConflict: neverCalled)
        try runner.undo(result.steps)

        #expect(try read(file) == "one")
        #expect(!exists(dest.appendingPathComponent("a.txt")))
    }

    @Test func undoReplaceRestoresTheOriginal() async throws {
        let root = try TempDir()
        let source = root.url.appendingPathComponent("src/a.txt")
        try write("new", to: source)
        let existing = root.url.appendingPathComponent("dest/a.txt")
        try write("old", to: existing)
        let runner = try makeRunner(root)

        let result = try await runner.transfer(
            [source], to: existing.deletingLastPathComponent(), mode: .copy, onConflict: { _ in .replace })
        try runner.undo(result.steps)

        #expect(try read(existing) == "old")
    }

    @Test func trashAndUndoRestores() throws {
        let root = try TempDir()
        let file = root.url.appendingPathComponent("a.txt")
        try write("one", to: file)
        let runner = try makeRunner(root)

        let steps = try runner.trash([file])
        #expect(!exists(file))
        try runner.undo(steps)
        #expect(try read(file) == "one")
    }

    @Test func renameValidatesNames() throws {
        let root = try TempDir()
        let file = root.url.appendingPathComponent("a.txt")
        try write("one", to: file)
        try write("two", to: root.url.appendingPathComponent("b.txt"))
        let runner = try makeRunner(root)

        for bad in ["", "  ", "x/y", ".", "..", "b.txt"] {
            #expect(throws: FileOperationError.self, "name \(bad)") { try runner.rename(file, to: bad) }
        }
        let renamed = try runner.rename(file, to: "c.txt")
        #expect(renamed.url.lastPathComponent == "c.txt")
        #expect(renamed.step == .moved(from: file, to: renamed.url))
        #expect(try read(renamed.url) == "one")
    }

    @Test func caseOnlyRenameIsAllowed() throws {
        let root = try TempDir()
        let file = root.url.appendingPathComponent("readme.md")
        try write("one", to: file)

        let renamed = try makeRunner(root).rename(file, to: "README.md")

        #expect(renamed.url.lastPathComponent == "README.md")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.url.path)
        #expect(names.contains("README.md"))
    }

    @Test func newFolderGetsAUniqueName() throws {
        let root = try TempDir()
        try root.folder("untitled folder")
        let runner = try makeRunner(root)

        let created = try runner.createFolder(in: root.url)

        #expect(created.url.lastPathComponent == "untitled folder 2")
        try runner.undo([created.step])
        #expect(!exists(created.url))
    }
}

struct DropRuleTests {
    @Test func finderDragRules() {
        #expect(DropRules.mode(sameVolume: true, option: false, command: false) == .move)
        #expect(DropRules.mode(sameVolume: false, option: false, command: false) == .copy)
        #expect(DropRules.mode(sameVolume: true, option: true, command: false) == .copy)
        #expect(DropRules.mode(sameVolume: false, option: false, command: true) == .move)
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class LastProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: OperationProgress?
    func set(_ progress: OperationProgress) { lock.withLock { stored = progress } }
    var value: OperationProgress? { lock.withLock { stored } }
}
