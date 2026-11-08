import Foundation
import Testing
@testable import FennecCore

final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fennec-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String, bytes: Int = 0) throws {
        try Data(count: bytes).write(to: url.appendingPathComponent(name))
    }

    func folder(_ name: String) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(name), withIntermediateDirectories: true)
    }
}

struct DirectoryLoaderTests {
    @Test func listsFilesFoldersAndHiddenEntries() throws {
        let dir = try TempDir()
        try dir.file("notes.txt", bytes: 5)
        try dir.folder("Sub")
        try dir.file(".secret")

        let entries = try DirectoryLoader.loadSync(dir.url)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        #expect(byName.count == 3)
        #expect(byName["notes.txt"]?.size == 5)
        #expect(byName["notes.txt"]?.typeIdentifier == "public.plain-text")
        #expect(byName["notes.txt"]?.modified != nil)
        #expect(byName["Sub"]?.isBrowsable == true)
        #expect(byName[".secret"]?.isHidden == true)
        #expect(byName["notes.txt"]?.cloudStatus == CloudStatus.none)
    }

    @Test func treatsAppBundlesAsFiles() throws {
        let dir = try TempDir()
        try dir.folder("Tool.app")

        let entry = try #require(try DirectoryLoader.loadSync(dir.url).first)

        #expect(entry.isDirectory)
        #expect(entry.isPackage)
        #expect(!entry.isBrowsable)
    }

    @Test func itemCountSkipsHiddenFilesUnlessShown() throws {
        let dir = try TempDir()
        try dir.file("a.txt")
        try dir.file("b.txt")
        try dir.file(".DS_Store")

        #expect(DirectoryLoader.itemCount(at: dir.url, includeHidden: false) == 2)
        #expect(DirectoryLoader.itemCount(at: dir.url, includeHidden: true) == 3)
    }

    @Test func missingFolderThrows() {
        let missing = URL(filePath: "/definitely/not/here-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try DirectoryLoader.loadSync(missing) }
    }

    @Test func detectsICloudPaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Notes")
        #expect(DirectoryLoader.isInICloud(iCloud))
        #expect(!DirectoryLoader.isInICloud(home.appendingPathComponent("Documents")))
    }
}
