import Foundation
import Testing
@testable import FennecCore

private func file(_ name: String, size: Int64? = nil, hidden: Bool = false) -> FileEntry {
    FileEntry(url: URL(filePath: "/x/\(name)"), size: size, isHidden: hidden)
}

private func folder(_ name: String) -> FileEntry {
    FileEntry(url: URL(filePath: "/x/\(name)", directoryHint: .isDirectory), isDirectory: true)
}

private extension FileEntry {
    init(url: URL, size: Int64?, isHidden: Bool) {
        self.init(url: url, isHidden: isHidden, size: size)
    }
}

struct SortingTests {
    @Test func foldersComeFirstInBothDirections() {
        let entries = [file("a.txt"), folder("Zeta"), file("b.txt"), folder("Alpha")]

        let up = Sorting.sorted(entries, by: SortOrder(key: .name, ascending: true)).map(\.name)
        let down = Sorting.sorted(entries, by: SortOrder(key: .name, ascending: false)).map(\.name)

        #expect(up == ["Alpha", "Zeta", "a.txt", "b.txt"])
        #expect(down == ["Zeta", "Alpha", "b.txt", "a.txt"])
    }

    @Test func namesSortNaturallyAndIgnoreCase() {
        let entries = [file("file10"), file("File2"), file("file1")]
        let names = Sorting.sorted(entries, by: SortOrder()).map(\.name)
        #expect(names == ["file1", "File2", "file10"])
    }

    @Test func numbersCompareByValueIgnoringLeadingZeros() {
        let entries = [file("img-100.jpg"), file("img-020.jpg"), file("img-3.jpg"), file("img-.jpg")]
        let names = Sorting.sorted(entries, by: SortOrder()).map(\.name)
        #expect(names == ["img-.jpg", "img-3.jpg", "img-020.jpg", "img-100.jpg"])
    }

    @Test func kindSortGroupsByType() throws {
        let entries = [
            FileEntry(url: URL(filePath: "/x/b.txt"), typeIdentifier: "public.plain-text"),
            FileEntry(url: URL(filePath: "/x/a.png"), typeIdentifier: "public.png"),
            FileEntry(url: URL(filePath: "/x/a.txt"), typeIdentifier: "public.plain-text"),
        ]
        let names = Sorting.sorted(entries, by: SortOrder(key: .kind, ascending: true)).map(\.name)
        let firstText = try #require(names.firstIndex(of: "a.txt"))
        #expect(names[firstText + 1] == "b.txt")
    }

    // Type IDs order these pdf, jpg, txt (com.adobe < public.*); the visible labels order them jpg, pdf, txt.
    @Test func kindSortFollowsTheVisibleLabel() {
        let entries = [
            FileEntry(url: URL(filePath: "/x/a.txt"), typeIdentifier: "public.plain-text"),
            FileEntry(url: URL(filePath: "/x/a.pdf"), typeIdentifier: "com.adobe.pdf"),
            FileEntry(url: URL(filePath: "/x/a.jpg"), typeIdentifier: "public.jpeg"),
        ]
        let names = Sorting.sorted(entries, by: SortOrder(key: .kind, ascending: true)).map(\.name)
        #expect(names == ["a.jpg", "a.pdf", "a.txt"])
    }

    @Test func sizeSortFallsBackToNameOnTies() {
        let entries = [file("b", size: 10), file("a", size: 10), file("c", size: 1)]
        let names = Sorting.sorted(entries, by: SortOrder(key: .size, ascending: true)).map(\.name)
        #expect(names == ["c", "a", "b"])
    }

    @Test func hiddenEntriesAreFilteredUnlessShown() {
        let entries = [file(".env", hidden: true), file("main.go")]
        #expect(Sorting.arrange(entries, showHidden: false, order: SortOrder()).map(\.name) == ["main.go"])
        #expect(Sorting.arrange(entries, showHidden: true, order: SortOrder()).count == 2)
    }
}
