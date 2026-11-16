import Foundation
import Testing
@testable import FennecCore

struct TrashLedgerTests {
    @Test func remembersWhereATrashedItemCameFrom() throws {
        let dir = try TempDir()
        try dir.folder("Trash/Folder")
        let ledger = TrashLedger(file: dir.url.appendingPathComponent("ledger.json"))

        ledger.record(original: URL(filePath: "/Users/me/Docs/Folder"), trashed: dir.url.appendingPathComponent("Trash/Folder"))

        // Finder lists folders with a trailing slash.
        #expect(ledger.original(of: dir.url.appendingPathComponent("Trash/Folder/"))?.path == "/Users/me/Docs/Folder")
        #expect(ledger.original(of: dir.url.appendingPathComponent("Trash/Other")) == nil)
    }

    @Test func survivesARelaunch() throws {
        let dir = try TempDir()
        try dir.file("a.txt")
        let file = dir.url.appendingPathComponent("ledger.json")
        let trashed = dir.url.appendingPathComponent("a.txt")
        TrashLedger(file: file).record(original: URL(filePath: "/Users/me/a.txt"), trashed: trashed)

        #expect(TrashLedger(file: file).original(of: trashed)?.path == "/Users/me/a.txt")
    }

    @Test func forgetsItemsThatLeftTheTrash() throws {
        let dir = try TempDir()
        try dir.file("kept.txt")
        let file = dir.url.appendingPathComponent("ledger.json")
        let kept = dir.url.appendingPathComponent("kept.txt")
        let gone = dir.url.appendingPathComponent("gone.txt")
        let ledger = TrashLedger(file: file)
        ledger.record(original: URL(filePath: "/a/kept.txt"), trashed: kept)
        ledger.record(original: URL(filePath: "/a/gone.txt"), trashed: gone)

        ledger.prune()

        #expect(TrashLedger(file: file).original(of: kept) != nil)
        #expect(TrashLedger(file: file).original(of: gone) == nil)
    }
}
