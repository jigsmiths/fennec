import Foundation
import Testing
@testable import FennecCore

struct FileInfoTests {
    @Test func permissionsAsSymbols() {
        #expect(FileInfoFormatting.permissions(0o755) == "rwxr-xr-x")
        #expect(FileInfoFormatting.permissions(0o644) == "rw-r--r--")
        #expect(FileInfoFormatting.permissions(0o000) == "---------")
    }

    @Test func locationShortensHome() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        #expect(FileInfoFormatting.location(of: URL(filePath: "/Users/me/Documents/a.txt"), home: home) == "~/Documents")
        #expect(FileInfoFormatting.location(of: URL(filePath: "/Users/me/a.txt"), home: home) == "~")
        #expect(FileInfoFormatting.location(of: URL(filePath: "/Users/meg/a.txt"), home: home) == "/Users/meg")
        #expect(FileInfoFormatting.location(of: URL(filePath: "/tmp/a.txt"), home: home) == "/tmp")
    }

    @Test func enclosingFolderOfAFolderIsItsParent() {
        let folders = FileInfoFormatting.enclosingFolders(of: [
            URL(filePath: "/Users/me/Documents/Photos/", directoryHint: .isDirectory),
        ])
        #expect(folders.map(\.path) == ["/Users/me/Documents"])
    }

    @Test func enclosingFoldersSkipRepeatsAndKeepOrder() {
        let folders = FileInfoFormatting.enclosingFolders(of: [
            URL(filePath: "/b/one.txt"),
            URL(filePath: "/a/two.txt"),
            URL(filePath: "/b/Sub/", directoryHint: .isDirectory),
        ])
        #expect(folders.map(\.path) == ["/b", "/a"])
    }

    @Test func smallSizesSkipTheExactCount() {
        #expect(FileInfoFormatting.size(12) == "12 bytes")
    }

    @Test func largeSizesShowExactBytes() {
        #expect(FileInfoFormatting.size(1_234_567).hasSuffix("(\(Int64(1_234_567).formatted()) bytes)"))
    }

    @Test func folderSizeCountsItems() {
        #expect(FileInfoFormatting.folderSize(bytes: 5, items: 1) == "5 bytes for 1 item")
        #expect(FileInfoFormatting.folderSize(bytes: 5, items: 2) == "5 bytes for 2 items")
    }

    @Test func folderTotalsIncludeNestedAndHiddenFiles() throws {
        let dir = try TempDir()
        try dir.file("a.txt", bytes: 10)
        try dir.file(".hidden", bytes: 5)
        try dir.folder("Sub")
        try dir.file("Sub/b.txt", bytes: 20)

        let totals = try #require(FileInfo.folderTotals(dir.url))

        #expect(totals.bytes == 35)
        #expect(totals.items == 4)
    }

    @Test func folderTotalsStopWhenCancelled() throws {
        let dir = try TempDir()
        try dir.file("a.txt")
        #expect(FileInfo.folderTotals(dir.url, isCancelled: { true }) == nil)
    }

    @Test func loadReadsDatesAndPermissions() throws {
        let dir = try TempDir()
        try dir.file("a.txt")
        let url = dir.url.appendingPathComponent("a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)

        let info = FileInfo.load(url)

        #expect(info.permissions == 0o640)
        #expect(info.modified != nil)
        #expect(info.created != nil)
        #expect(info.owner == NSUserName())
    }
}
