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
}
