import Foundation
import Testing
@testable import FennecCore

struct StatusTextTests {
    private let progress = FolderWalker.Progress(files: 182_400, bytes: 0, folder: "Caches")

    @Test func contentsCountsItemsWithNothingSelected() {
        #expect(StatusText.contents(itemCount: 1, selection: []) == "1 item")
        #expect(StatusText.contents(itemCount: 1200, selection: []) == "\(1200.formatted()) items")
    }

    @Test func contentsDescribesTheSelection() {
        let file = FileEntry(url: URL(filePath: "/x/a.txt"), size: 2000)
        #expect(StatusText.contents(itemCount: 9, selection: [file]) == SelectionSummary.describe([file]))
    }

    @Test func scanCountsFilesOnAFirstWalk() {
        let text = StatusText.scan(name: "Library", progress: progress, expectedFiles: nil, queued: 0)
        #expect(text == "Sizing Library · \(Int64(182_400).formatted()) files")
    }

    @Test func scanShowsAPercentageAgainstTheLastWalk() {
        let text = StatusText.scan(name: "Library", progress: progress, expectedFiles: 400_000, queued: 3)
        #expect(text == "Sizing Library · \(0.456.formatted(.percent.precision(.fractionLength(0)))) · 3 queued")
    }
}
