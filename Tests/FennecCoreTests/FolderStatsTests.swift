import Foundation
import Testing
@testable import FennecCore

struct FolderStatsTests {
    private let stats = FolderStats(bytes: 42, calculated: Date(timeIntervalSince1970: 0))

    @Test func applySetsFoldersAndPackagesByNormalizedName() {
        let entries = [
            FileEntry(url: URL(filePath: "/x/Cafe\u{301}"), isDirectory: true),
            FileEntry(url: URL(filePath: "/x/Tool.app"), isDirectory: true, isPackage: true),
            FileEntry(url: URL(filePath: "/x/Other"), isDirectory: true),
            FileEntry(url: URL(filePath: "/x/Caf\u{E9}.txt"), size: 3),
        ]
        let known = ["Caf\u{E9}": stats, "Tool.app": stats, "Caf\u{E9}.txt": stats]

        let applied = FolderStats.apply(known, to: entries)

        #expect(applied.map(\.folderStats) == [stats, stats, nil, nil])
    }

    @Test func applyClearsStatsThatAreNoLongerKnown() {
        var entry = FileEntry(url: URL(filePath: "/x/Sub"), isDirectory: true)
        entry.folderStats = stats

        #expect(FolderStats.apply([:], to: [entry]).first?.folderStats == nil)
    }
}
