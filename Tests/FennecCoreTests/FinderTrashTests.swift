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

    @Test func symlinksSkipFinderAndOrderIsKept() throws {
        let dir = try TempDir()
        try dir.file("a.txt")
        try dir.file("c.txt")
        let a = dir.url.appendingPathComponent("a.txt")
        let link = dir.url.appendingPathComponent("b-link")
        let c = dir.url.appendingPathComponent("c.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        var finderCalls: [[URL]] = []
        var systemCalls: [URL] = []

        let trashed = try FinderTrash.trash(
            [a, link, c],
            finder: { urls in finderCalls.append(urls); return urls.map { URL(filePath: "/Finder/\($0.lastPathComponent)") } },
            system: { url in systemCalls.append(url); return URL(filePath: "/System/\(url.lastPathComponent)") })

        #expect(finderCalls == [[a, c]])
        #expect(systemCalls == [link])
        #expect(trashed.map(\.path) == ["/Finder/a.txt", "/System/b-link", "/Finder/c.txt"])
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

    @Test func deniedAutomationGetsItsOwnError() {
        let stderr = "0:120: execution error: Not authorized to send Apple events to Finder. (-1743)\n"

        #expect(FinderTrash.failure(fromStderr: stderr) == .automationDenied)
    }

    @Test func otherErrorsKeepFindersMessage() {
        let stderr = "0:200: execution error: Finder got an error: Can’t get item \"x\". (-1728)\n"

        #expect(FinderTrash.failure(fromStderr: stderr) == .finder("Finder got an error: Can’t get item \"x\"."))
    }
}
