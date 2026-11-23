import Foundation
import Testing
@testable import FennecCore

@Suite struct FolderStatsStoreTests {
    private let dir: TempDir
    private let file: URL
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        dir = try TempDir()
        file = dir.url.appendingPathComponent("stats.sqlite")
    }

    private func stats(_ bytes: Int64, at date: Date? = nil) -> FolderStats {
        FolderStats(bytes: bytes, allocated: bytes, files: 1, calculated: date ?? now)
    }

    private func walk(_ folders: [(String, Int64)], at date: Date? = nil) -> FolderWalk {
        var walk = FolderWalk()
        var indexes: [String: Int] = [:]
        for (path, bytes) in folders {
            let parent = path.isEmpty ? -1 : indexes[(path as NSString).deletingLastPathComponent] ?? 0
            indexes[path] = walk.folders.count
            walk.folders.append(.init(
                parent: parent, name: (path as NSString).lastPathComponent, stats: stats(bytes, at: date)))
        }
        return walk
    }

    private let root = URL(filePath: "/Users/someone/Projects", directoryHint: .isDirectory)

    @Test func savesAndReadsBackAWalk() async throws {
        let store = try FolderStatsStore(url: file)
        try await store.save(walk([("", 30), ("app", 20), ("app/src", 15), ("docs", 10)]), at: root)

        #expect(try await store.stats(for: root) == stats(30))
        #expect(try await store.stats(for: root.appending(path: "app/src")) == stats(15))
        let children = try await store.childStats(of: root)
        #expect(children == ["app": stats(20), "docs": stats(10)])
    }

    @Test func roundTripsEveryStatsField() async throws {
        let rootStats = FolderStats(
            bytes: 1, allocated: 2, files: 3, subfolders: 4, newest: Date(timeIntervalSince1970: 5),
            calculated: Date(timeIntervalSince1970: 6), durationMilliseconds: 7, incomplete: true)
        let childStats = FolderStats(
            bytes: 11, allocated: 12, files: 13, subfolders: 14, newest: Date(timeIntervalSince1970: 15),
            calculated: Date(timeIntervalSince1970: 16), durationMilliseconds: 17, incomplete: true)
        var walk = FolderWalk()
        walk.folders.append(.init(parent: -1, name: "", stats: rootStats))
        walk.folders.append(.init(parent: 0, name: "child", stats: childStats))
        let store = try FolderStatsStore(url: file)

        try await store.save(walk, at: root)

        #expect(try await store.stats(for: root) == rootStats)
        #expect(try await store.childStats(of: root) == ["child": childStats])
    }

    @Test func foldersOnlyOnTheWayToARootHaveNoStats() async throws {
        let store = try FolderStatsStore(url: file)
        try await store.save(walk([("", 30)]), at: root)

        #expect(try await store.stats(for: URL(filePath: "/Users/someone")) == nil)
        #expect(try await store.childStats(of: URL(filePath: "/Users")).isEmpty)
        #expect(try await store.stats(for: URL(filePath: "/Elsewhere")) == nil)
    }

    @Test func savingAgainReplacesWhatWasUnderTheRoot() async throws {
        let store = try FolderStatsStore(url: file)
        try await store.save(walk([("", 30), ("old", 20), ("old/deep", 5), ("kept", 10)]), at: root)
        try await store.save(walk([("", 12), ("kept", 12)]), at: root)

        #expect(try await store.childStats(of: root) == ["kept": stats(12)])
        #expect(try await store.stats(for: root.appending(path: "old/deep")) == nil)
    }

    @Test func savingASubfolderLeavesItsParentAlone() async throws {
        let store = try FolderStatsStore(url: file)
        try await store.save(walk([("", 30), ("app", 20), ("docs", 10)]), at: root)
        try await store.save(walk([("", 25)]), at: root.appending(path: "app"))

        #expect(try await store.stats(for: root) == stats(30))
        #expect(try await store.childStats(of: root) == ["app": stats(25), "docs": stats(10)])
    }

    @Test func savesTheWholeDiskUnderTheRootRow() async throws {
        let store = try FolderStatsStore(url: file)
        try await store.save(walk([("", 100), ("Users", 60)]), at: URL(filePath: "/"))

        #expect(try await store.stats(for: URL(filePath: "/")) == stats(100))
        #expect(try await store.childStats(of: URL(filePath: "/")) == ["Users": stats(60)])
    }

    @Test func matchesNamesInEitherUnicodeForm() async throws {
        let store = try FolderStatsStore(url: file)
        let decomposed = "Cafe\u{301}"
        let precomposed = "Caf\u{E9}"
        try await store.save(walk([("", 8), (decomposed, 8)]), at: root)

        #expect(try await store.stats(for: root.appending(path: precomposed)) == stats(8))
        #expect(try await store.childStats(of: root).keys.first == FolderStatsStore.normalized(decomposed))
    }

    @Test func listsTheStalestFoldersFirst() async throws {
        let store = try FolderStatsStore(url: file)
        try await store.save(walk([("", 1)], at: now), at: root.appending(path: "b"))
        try await store.save(walk([("", 1)], at: now - 100), at: root.appending(path: "a"))
        try await store.save(walk([("", 1)], at: now + 100), at: root.appending(path: "c"))

        let stalest = try await store.stalest(limit: 2)

        #expect(stalest.map(\.path) == [root.appending(path: "a").path, root.appending(path: "b").path])
    }

    @Test func keepsStatsAcrossReopening() async throws {
        var store: FolderStatsStore? = try FolderStatsStore(url: file)
        try await store?.save(walk([("", 30)]), at: root)
        store = nil

        let reopened = try FolderStatsStore(url: file)
        #expect(try await reopened.stats(for: root) == stats(30))
    }

    @Test func startsOverOnAnotherSchemaVersion() async throws {
        var store: FolderStatsStore? = try FolderStatsStore(url: file)
        try await store?.save(walk([("", 30)]), at: root)
        store = nil
        try Database(path: file.path).execute("PRAGMA user_version = 99")

        let reopened = try FolderStatsStore(url: file)
        #expect(try await reopened.stats(for: root) == nil)
        try await reopened.save(walk([("", 5)]), at: root)
        #expect(try await reopened.stats(for: root) == stats(5))
    }

    @Test func startsOverWhenTheFileIsNotADatabase() async throws {
        try Data("not a database".utf8).write(to: file)

        let store = try FolderStatsStore(url: file)
        try await store.save(walk([("", 5)]), at: root)
        #expect(try await store.stats(for: root) == stats(5))
    }

    @Test func everyQueryUsesAnIndex() async throws {
        let store = try FolderStatsStore(url: file)
        let plans = try await store.queryPlans()

        #expect(plans.count == FolderStatsStore.SQL.queries.count)
        for (sql, details) in plans {
            #expect(!details.contains { $0.hasPrefix("SCAN") }, "\(sql): \(details)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FENNEC_PERF"] != nil))
    func performanceWithAMillionFolders() async throws {
        let store = try FolderStatsStore(url: file)
        var big = FolderWalk()
        big.folders.append(.init(parent: -1, name: "", stats: stats(0)))
        for a in 0..<1000 {
            let parent = big.folders.count
            big.folders.append(.init(parent: 0, name: "folder-\(a)", stats: stats(Int64(a))))
            for b in 0..<999 {
                big.folders.append(.init(parent: parent, name: "child-\(b)", stats: stats(Int64(b))))
            }
        }
        let clock = ContinuousClock()

        let save = try await clock.measure { try await store.save(big, at: root) }
        let lookup = try await clock.measure {
            for a in 0..<1000 { _ = try await store.stats(for: root.appending(path: "folder-\(a)/child-500")) }
        }
        let children = try await clock.measure {
            for a in 0..<100 { _ = try await store.childStats(of: root.appending(path: "folder-\(a)")) }
        }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        print("""
            \(big.folders.count) folders: save \(save), 1000 lookups \(lookup), \
            100 × childStats(999) \(children), file \(size / 1_000_000) MB
            """)
    }
}
