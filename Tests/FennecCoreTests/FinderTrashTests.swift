import Foundation
import Testing
@testable import FennecCore

/// Runs only the script's locate step (no Finder involved) and returns what Finder would be told to delete.
private func locate(_ url: URL) throws -> String {
    let wrapper = FinderTrash.locateHandler + """

        on run argv
            set {folderPath, itemName} to locate(item 1 of argv, item 2 of argv)
            return folderPath & " | " & itemName
        end run
        """
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/osascript")
    process.arguments = ["-e", wrapper] + FinderTrash.arguments(for: [url])
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct FinderTrashTests {
    @Test func namesTheLinkNotItsTarget() throws {
        let dir = try TempDir()
        try dir.file("Target.txt")
        let link = dir.url.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.url.appendingPathComponent("Target.txt"))

        let located = try locate(link)

        #expect(located.hasSuffix(" | Link"))
        #expect(!located.contains("Target"))
    }

    private static let noPermission = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)

    private final class FakeFinder {
        var calls: [[URL]] = []
        func trash(_ urls: [URL]) -> [URL] {
            calls.append(urls)
            return urls.map { URL(filePath: "/Finder/\($0.lastPathComponent)") }
        }
    }

    @Test func systemTrashIsTriedFirstWithoutFinder() throws {
        let dir = try TempDir()
        try dir.file("a.txt")
        let a = dir.url.appendingPathComponent("a.txt")
        let finder = FakeFinder()

        let trashed = try FinderTrash.trash(
            [a], finder: finder.trash, system: { URL(filePath: "/System/\($0.lastPathComponent)") })

        #expect(finder.calls.isEmpty)
        #expect(trashed.map(\.path) == ["/System/a.txt"])
    }

    @Test func permissionDeniedFallsBackToFinderAndOrderIsKept() throws {
        let dir = try TempDir()
        for name in ["a.txt", "b.txt", "d.txt"] { try dir.file(name) }
        let a = dir.url.appendingPathComponent("a.txt")
        let b = dir.url.appendingPathComponent("b.txt")
        let link = dir.url.appendingPathComponent("c-link")
        let d = dir.url.appendingPathComponent("d.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let finder = FakeFinder()

        let trashed = try FinderTrash.trash(
            [a, b, link, d], finder: finder.trash,
            system: { url in
                if url == b || url == d { throw Self.noPermission }
                return URL(filePath: "/System/\(url.lastPathComponent)")
            })

        #expect(finder.calls == [[b, d]])
        #expect(trashed.map(\.path) == ["/System/a.txt", "/Finder/b.txt", "/System/c-link", "/Finder/d.txt"])
    }

    @Test func symlinksNeverGoToFinder() throws {
        let dir = try TempDir()
        try dir.file("a.txt")
        let link = dir.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.url.appendingPathComponent("a.txt"))
        let finder = FakeFinder()

        #expect(throws: NSError.self) {
            try FinderTrash.trash([link], finder: finder.trash, system: { _ in throw Self.noPermission })
        }
        #expect(finder.calls.isEmpty)
    }

    @Test func otherSystemErrorsAreThrown() throws {
        let dir = try TempDir()
        try dir.file("a.txt")
        let finder = FakeFinder()

        #expect(throws: NSError.self) {
            try FinderTrash.trash(
                [dir.url.appendingPathComponent("a.txt")], finder: finder.trash,
                system: { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError) })
        }
        #expect(finder.calls.isEmpty)
    }

    @Test func colonsInNamesBecomeFinderSlashes() {
        let args = FinderTrash.arguments(for: [URL(filePath: "/tmp/IND Family:Friends.pdf")])

        #expect(args == ["/tmp", "IND Family/Friends.pdf"])
    }

    @Test func readsOneTrashedPathPerLine() throws {
        let urls = try FinderTrash.trashedURLs(from: "/Users/me/.Trash/a.txt\n/Users/me/.Trash/Folder/\n", count: 2)

        #expect(urls.map(\.path) == ["/Users/me/.Trash/a.txt", "/Users/me/.Trash/Folder"])
    }

    @Test func missingResultsAreAnError() {
        #expect(throws: FinderTrash.Failure.self) {
            try FinderTrash.trashedURLs(from: "/Users/me/.Trash/a.txt\n", count: 2)
        }
    }

    @Test func readsTrashListingAsFileURLs() {
        let urls = FinderTrash.itemURLs(from: "file:///Users/me/.Trash/a%20b.txt\nfile:///Users/me/.Trash/Folder/\n")

        #expect(urls.map(\.path) == ["/Users/me/.Trash/a b.txt", "/Users/me/.Trash/Folder"])
    }

    @Test func emptyTrashListsNothing() {
        #expect(FinderTrash.itemURLs(from: "\n").isEmpty)
    }

    @Test func recognisesTheTrashFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(FinderTrash.isTrash(home.appendingPathComponent(".Trash/")))
        #expect(!FinderTrash.isTrash(home.appendingPathComponent(".Trash/Folder")))
    }

    @Test func knowsWhichFoldersAreInsideTheHomeTrash() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(FinderTrash.isInsideHomeTrash(home.appendingPathComponent(".Trash/Folder/Sub")))
        #expect(!FinderTrash.isInsideHomeTrash(home.appendingPathComponent(".Trash")))
        #expect(!FinderTrash.isInsideHomeTrash(home.appendingPathComponent(".Trashy/Folder")))
    }

    @Test func onlyPrivacyBlocksInsideTheTrashNeedFullDiskAccess() {
        let inTrash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/Folder")
        func readError(_ posix: Int32) -> Error {
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(posix))])
        }

        #expect(FinderTrash.needsFullDiskAccess(readError(EPERM), opening: inTrash))
        #expect(!FinderTrash.needsFullDiskAccess(readError(EACCES), opening: inTrash))
        #expect(!FinderTrash.needsFullDiskAccess(readError(EPERM), opening: URL(filePath: "/tmp/Folder")))
    }

    @Test func deniedAutomationGetsItsOwnError() {
        let stderr = "0:120: execution error: Not authorized to send Apple events to Finder. (-1743)\n"

        #expect(FinderTrash.failure(fromStderr: stderr) == .automationDenied)
    }

    @Test func otherErrorsKeepFindersMessage() {
        let stderr = "0:200: execution error: Finder got an error: Can’t get item \"x\". (-1728)\n"

        #expect(FinderTrash.failure(fromStderr: stderr) == .finder("Finder got an error: Can’t get item \"x\"."))
    }
}
