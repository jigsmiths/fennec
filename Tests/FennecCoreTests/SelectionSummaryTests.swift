import Foundation
import Testing
@testable import FennecCore

struct SelectionSummaryTests {
    private func file(_ name: String, _ size: Int64) -> FileEntry {
        FileEntry(url: URL(filePath: "/x/\(name)"), size: size)
    }

    private func folder(_ name: String) -> FileEntry {
        FileEntry(url: URL(filePath: "/x/\(name)"), isDirectory: true, size: 64)
    }

    @Test func filesShowCountAndTotalSize() {
        let summary = SelectionSummary.describe([file("a", 1000), file("b", 1000), file("c", 1000)])
        #expect(summary == "3 items, \(FileFormatting.bytes(3000))")
    }

    @Test func mixedSelectionCountsFoldersAndOnlySumsFiles() {
        let summary = SelectionSummary.describe([file("a", 2000), folder("Sub"), file("b", 2000)])
        #expect(summary == "3 items (1 folder), \(FileFormatting.bytes(4000))")
    }

    @Test func foldersOnlyHaveNoSize() {
        #expect(SelectionSummary.describe([folder("A"), folder("B")]) == "2 folders")
    }

    private func measured(_ name: String, _ bytes: Int64) -> FileEntry {
        var entry = folder(name)
        entry.folderStats = FolderStats(bytes: bytes, calculated: Date())
        return entry
    }

    @Test func foldersShowTheTotalOfThoseWithStats() {
        #expect(SelectionSummary.describe([measured("A", 3000), folder("B")]) == "2 folders, \(FileFormatting.bytes(3000))")
    }

    @Test func mixedSelectionAddsFolderTotals() {
        let summary = SelectionSummary.describe([file("a", 2000), measured("Sub", 5000)])
        #expect(summary == "2 items (1 folder), \(FileFormatting.bytes(7000))")
    }
}
