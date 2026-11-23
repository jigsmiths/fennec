import Foundation
import Testing
@testable import FennecCore

@Suite struct FolderWalkerTests {
    private func walk(_ url: URL) throws -> [String: FolderStats] {
        let walk = try #require(FolderWalker.walk(url))
        var paths: [String] = []
        for folder in walk.folders {
            paths.append(folder.parent < 0 ? "" : (paths[folder.parent].isEmpty ? "" : paths[folder.parent] + "/") + folder.name)
        }
        return Dictionary(uniqueKeysWithValues: zip(paths, walk.folders.map(\.stats)))
    }

    @Test func totalsEveryFolderFromItsContents() throws {
        let dir = try TempDir()
        try dir.folder("sub/deep")
        try dir.file("a.txt", bytes: 5)
        try dir.file("sub/b.txt", bytes: 10)
        try dir.file("sub/deep/c.txt", bytes: 20)

        let stats = try walk(dir.url)

        #expect(stats.keys.sorted() == ["", "sub", "sub/deep"])
        #expect(stats[""]?.bytes == 35)
        #expect(stats[""]?.files == 3)
        #expect(stats[""]?.subfolders == 2)
        #expect(stats["sub"]?.bytes == 30)
        #expect(stats["sub"]?.files == 2)
        #expect(stats["sub"]?.subfolders == 1)
        #expect(stats["sub/deep"]?.bytes == 20)
        #expect(stats["sub/deep"]?.subfolders == 0)
        #expect(try #require(stats[""]?.allocated) > 0)
        #expect(stats[""]?.incomplete == false)
    }

    @Test func listsParentsBeforeChildren() throws {
        let dir = try TempDir()
        try dir.folder("a/b/c")
        try dir.folder("d")

        let walk = try #require(FolderWalker.walk(dir.url))

        #expect(walk.folders.first?.parent == -1)
        for (index, folder) in walk.folders.enumerated().dropFirst() {
            #expect(folder.parent < index)
        }
    }

    @Test func countsHiddenFiles() throws {
        let dir = try TempDir()
        try dir.file(".env", bytes: 4)
        try dir.folder(".config")
        try dir.file(".config/settings.json", bytes: 6)

        let stats = try walk(dir.url)

        #expect(stats[""]?.bytes == 10)
        #expect(stats[".config"]?.files == 1)
    }

    @Test func doesNotFollowSymlinks() throws {
        let outside = try TempDir()
        try outside.file("big.bin", bytes: 10_000)
        let dir = try TempDir()
        try FileManager.default.createSymbolicLink(
            at: dir.url.appendingPathComponent("Link"), withDestinationURL: outside.url)

        let stats = try walk(dir.url)

        #expect(stats.keys.sorted() == [""])
        #expect(stats[""]?.files == 1)
        #expect(try #require(stats[""]?.bytes) < 10_000)
    }

    @Test func recordsPackagesButNotTheFoldersInside() throws {
        let dir = try TempDir()
        try dir.folder("Tool.app/Contents/MacOS")
        try dir.file("Tool.app/Contents/MacOS/tool", bytes: 7)

        let stats = try walk(dir.url)

        #expect(stats.keys.sorted() == ["", "Tool.app"])
        #expect(stats["Tool.app"]?.bytes == 7)
        #expect(stats["Tool.app"]?.subfolders == 2)
        #expect(stats[""]?.bytes == 7)
    }

    @Test func walkingAPackageRecordsOnlyThePackage() throws {
        let dir = try TempDir()
        try dir.folder("Tool.app/Contents/MacOS")
        try dir.file("Tool.app/Contents/MacOS/tool", bytes: 7)

        let stats = try walk(dir.url.appendingPathComponent("Tool.app"))

        #expect(stats.keys.sorted() == [""])
        #expect(stats[""]?.bytes == 7)
    }

    @Test func tracksTheNewestModificationInside() throws {
        let dir = try TempDir()
        try dir.folder("sub")
        try dir.file("sub/new.txt")
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: dir.url.appendingPathComponent("sub/new.txt").path)

        let stats = try walk(dir.url)

        #expect(stats[""]?.newest == date)
        #expect(stats["sub"]?.newest == date)
    }

    @Test func marksFoldersItCannotReadAsIncomplete() throws {
        let dir = try TempDir()
        try dir.folder("locked")
        try dir.file("locked/secret.txt", bytes: 3)
        let locked = dir.url.appendingPathComponent("locked").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

        let stats = try walk(dir.url)

        #expect(stats["locked"]?.incomplete == true)
        #expect(stats[""]?.incomplete == true)
        #expect(stats[""]?.bytes == 0)
    }

    @Test func reportsProgressAsItGoes() throws {
        let dir = try TempDir()
        try dir.folder("a/b")
        try dir.file("top.txt", bytes: 1)
        try dir.file("a/one.txt", bytes: 10)
        try dir.file("a/b/two.txt", bytes: 100)

        var reports: [FolderWalker.Progress] = []
        _ = FolderWalker.walk(dir.url, progressInterval: .zero) { reports.append($0) }

        #expect(reports.map(\.folder) == ["", "a", "a/b"])
        #expect(reports.map(\.files) == [1, 2, 3])
        #expect(reports.last?.bytes == 111)
    }

    @Test func progressFractionIsCappedBelowDone() {
        let halfway = FolderWalker.Progress(files: 50, bytes: 0, folder: "")
        let past = FolderWalker.Progress(files: 150, bytes: 0, folder: "")

        #expect(halfway.fraction(ofExpected: 100) == 0.5)
        #expect(past.fraction(ofExpected: 100) == 0.99)
        #expect(halfway.fraction(ofExpected: nil) == nil)
        #expect(halfway.fraction(ofExpected: 0) == nil)
    }

    @Test func stopsWhenCancelled() throws {
        let dir = try TempDir()
        try dir.folder("a/b")

        var checks = 0
        let walk = FolderWalker.walk(dir.url) { checks += 1; return checks > 1 }

        #expect(walk == nil)
    }

    @Test func readerFlagsMountPoints() throws {
        var dev: BulkReader.Entry?
        _ = BulkReader(details: true).list("/") { entry in
            if entry.name == "dev" { dev = entry }
            return true
        }

        #expect(try #require(dev?.details).isMountPoint)
    }
}
