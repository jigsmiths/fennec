import Foundation
import Testing
@testable import FennecCore

@Suite struct FileIndexerTests {
    private func paths(_ root: URL, includeHidden: Bool = false, limit: Int = 1000, batchSize: Int = 100) -> [String] {
        var all: [FileIndexer.Item] = []
        FileIndexer.walk(root, includeHidden: includeHidden, limit: limit, batchSize: batchSize) { all += $0 }
        return all.map(\.relativePath).sorted()
    }

    @Test func listsFilesAndFoldersRecursivelyWithRelativePaths() throws {
        let dir = try TempDir()
        try dir.folder("src/app")
        try dir.file("src/app/main.swift")
        try dir.file("README.md")

        #expect(paths(dir.url) == ["README.md", "src", "src/app", "src/app/main.swift"])
    }

    @Test func marksFoldersAndPackages() throws {
        let dir = try TempDir()
        try dir.folder("Sub")
        try dir.folder("Tool.app/Contents")
        try dir.file("a.txt")

        var items: [FileIndexer.Item] = []
        FileIndexer.walk(dir.url, includeHidden: false, limit: 100, batchSize: 10) { items += $0 }
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.relativePath, $0) })

        #expect(byPath["Sub"]?.isBrowsable == true)
        #expect(byPath["Tool.app"]?.isBrowsable == false)
        #expect(byPath["a.txt"]?.isBrowsable == false)
        #expect(byPath["Sub"]?.url(in: dir.url).path == dir.url.appendingPathComponent("Sub").path)
    }

    @Test func doesNotDescendIntoPackages() throws {
        let dir = try TempDir()
        try dir.folder("Tool.app/Contents")
        try dir.file("Tool.app/Contents/Info.plist")

        #expect(paths(dir.url) == ["Tool.app"])
    }

    @Test func skipsHiddenFilesUnlessShown() throws {
        let dir = try TempDir()
        try dir.file(".env")
        try dir.folder(".config")
        try dir.file(".config/settings.json")
        try dir.file("visible.txt")

        #expect(paths(dir.url) == ["visible.txt"])
        #expect(paths(dir.url, includeHidden: true) == [".config", ".config/settings.json", ".env", "visible.txt"])
    }

    @Test func skipsFoldersWithTheHiddenFlagUnlessShown() throws {
        let dir = try TempDir()
        try dir.folder("Secret")
        try dir.file("Secret/inside.txt")
        try dir.file("visible.txt")
        #expect(chflags(dir.url.appendingPathComponent("Secret").path, UInt32(UF_HIDDEN)) == 0)

        #expect(paths(dir.url) == ["visible.txt"])
        #expect(paths(dir.url, includeHidden: true) == ["Secret", "Secret/inside.txt", "visible.txt"])
    }

    @Test func doesNotFollowSymlinkedFolders() throws {
        let dir = try TempDir()
        try dir.folder("real")
        try dir.file("real/a.txt")
        try FileManager.default.createSymbolicLink(
            at: dir.url.appendingPathComponent("loop"), withDestinationURL: dir.url)

        var items: [FileIndexer.Item] = []
        FileIndexer.walk(dir.url, includeHidden: false, limit: 100, batchSize: 10) { items += $0 }
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.relativePath, $0) })

        #expect(byPath.keys.sorted() == ["loop", "real", "real/a.txt"])
        #expect(byPath["loop"]?.isBrowsable == false)
    }

    @Test func handlesNonASCIINames() throws {
        let dir = try TempDir()
        try dir.folder("Résumé")
        try dir.file("Résumé/naïve 日本.txt")

        #expect(paths(dir.url) == ["Résumé", "Résumé/naïve 日本.txt"])
    }

    @Test func listsLargeFoldersCompletely() throws {
        let dir = try TempDir()
        // More entries than one bulk-read buffer holds.
        for i in 0..<3000 { try dir.file("a-fairly-long-file-name-to-fill-the-buffer-\(i).txt") }

        #expect(paths(dir.url, limit: 10_000).count == 3000)
    }

    @Test func skipsGitAndNodeModulesEvenWhenHiddenFilesAreShown() throws {
        let dir = try TempDir()
        try dir.folder(".git/objects")
        try dir.folder("node_modules/left-pad")
        try dir.file("node_modules/left-pad/index.js")
        try dir.file("index.js")

        #expect(paths(dir.url, includeHidden: true) == ["index.js"])
    }

    @Test func keepsPathsRelativeToASymlinkedRoot() throws {
        let dir = try TempDir()
        try dir.folder("real/sub")
        try dir.file("real/sub/a.txt")
        let link = dir.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.url.appendingPathComponent("real"))

        var items: [FileIndexer.Item] = []
        FileIndexer.walk(link, includeHidden: false, limit: 100, batchSize: 10) { items += $0 }

        #expect(items.map(\.relativePath).sorted() == ["sub", "sub/a.txt"])
        #expect(items.allSatisfy { $0.url(in: link).path.hasPrefix(link.path + "/") })
    }

    @Test func listsShallowItemsBeforeDeeperOnes() throws {
        let dir = try TempDir()
        try dir.folder("a/a1")
        try dir.file("a/a1/a2.txt")
        try dir.folder("b/b1")
        try dir.file("b/b1/b2.txt")

        var depths: [Int] = []
        FileIndexer.walk(dir.url, includeHidden: false, limit: 100, batchSize: 10) { batch in
            depths += batch.map { $0.relativePath.split(separator: "/").count }
        }

        #expect(depths == [1, 1, 2, 2, 3, 3])
    }

    @Test func stopsAtTheLimit() throws {
        let dir = try TempDir()
        for i in 0..<20 { try dir.file("f\(i).txt") }

        #expect(paths(dir.url, limit: 5).count == 5)
    }

    @Test func deliversResultsInBatches() throws {
        let dir = try TempDir()
        for i in 0..<25 { try dir.file("f\(i).txt") }

        var sizes: [Int] = []
        FileIndexer.walk(dir.url, includeHidden: false, limit: 100, batchSize: 10) { sizes.append($0.count) }

        #expect(sizes == [10, 10, 5])
    }
}
