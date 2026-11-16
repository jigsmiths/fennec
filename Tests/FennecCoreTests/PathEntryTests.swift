import Foundation
import Testing
@testable import FennecCore

private func path(_ url: URL) -> String { url.standardizedFileURL.path }

/// URL equality also compares trailing slashes, so compare targets by path.
private func describe(_ target: PathEntry.Target) -> String {
    switch target {
    case .folder(let url): "folder \(path(url))"
    case .item(let url): "item \(path(url))"
    case .notFound: "not found"
    }
}

private func suggestions(
    _ text: String, base: URL, home: URL, includeHidden: Bool = false, limit: Int = 8
) -> [PathEntry.Suggestion] {
    let query = PathEntry.query(for: text, relativeTo: base, home: home)
    return PathEntry.suggestions(query, in: PathEntry.folders(in: query.folder),
                                 includeHidden: includeHidden, limit: limit, home: home)
}

struct PathEntryResolveTests {
    @Test func resolvesHomeAbsoluteAndRelativePaths() throws {
        let home = try TempDir()
        try home.folder("Documents/Work")
        let base = home.url.appendingPathComponent("Documents")
        let work = "folder \(path(base))/Work"
        func resolve(_ text: String) -> String { describe(PathEntry.resolve(text, relativeTo: base, home: home.url)) }

        #expect(resolve("~/Documents/Work/") == work)
        #expect(resolve(path(base) + "/Work") == work)
        #expect(resolve("Work") == work)
        #expect(resolve("Work/../..") == "folder \(path(home.url))")
        #expect(resolve("~") == "folder \(path(home.url))")
    }

    @Test func aFileOrPackageResolvesToAnItem() throws {
        let home = try TempDir()
        try home.file("notes.txt")
        try home.folder("Tool.app")

        #expect(describe(PathEntry.resolve("~/notes.txt", relativeTo: home.url, home: home.url))
            == "item \(path(home.url))/notes.txt")
        #expect(describe(PathEntry.resolve("~/Tool.app", relativeTo: home.url, home: home.url))
            == "item \(path(home.url))/Tool.app")
    }

    @Test func missingOrEmptyPathsAreNotFound() throws {
        let home = try TempDir()

        #expect(describe(PathEntry.resolve("~/Nope", relativeTo: home.url, home: home.url)) == "not found")
        #expect(describe(PathEntry.resolve("", relativeTo: home.url, home: home.url)) == "not found")
    }
}

struct PathEntrySuggestionTests {
    @Test func listsMatchingFoldersPrefixMatchesFirst() throws {
        let home = try TempDir()
        try home.folder("Documents")
        try home.folder("My Docs")
        try home.folder("docker")
        try home.folder("Desktop")
        try home.file("Doc.txt")

        let result = suggestions("~/doc", base: home.url, home: home.url)

        #expect(result.map(\.name) == ["docker", "Documents", "My Docs"])
        #expect(result.map(\.matchRange) == [NSRange(location: 0, length: 3), NSRange(location: 0, length: 3),
                                             NSRange(location: 3, length: 3)])
        #expect(result.map(\.completion) == ["~/docker/", "~/Documents/", "~/My Docs/"])
    }

    @Test func aTrailingSlashListsTheWholeFolderUpToTheLimit() throws {
        let home = try TempDir()
        for name in ["A", "B", "C", "D"] { try home.folder("Projects/\(name)") }

        let result = suggestions("~/Projects/", base: home.url, home: home.url, limit: 3)

        #expect(result.map(\.name) == ["A", "B", "C"])
        #expect(result.first?.matchRange == NSRange(location: 0, length: 0))
    }

    @Test func relativeTextCompletesAgainstTheCurrentFolder() throws {
        let home = try TempDir()
        try home.folder("Documents/Work")

        let result = suggestions("Wo", base: home.url.appendingPathComponent("Documents"), home: home.url)

        #expect(result.map(\.completion) == ["Work/"])
    }

    @Test func hiddenFoldersOnlyWhenShownOrTypedWithADot() throws {
        let home = try TempDir()
        try home.folder(".config")
        try home.folder("code")

        #expect(suggestions("~/c", base: home.url, home: home.url).map(\.name) == ["code"])
        #expect(suggestions("~/c", base: home.url, home: home.url, includeHidden: true).map(\.name)
            == ["code", ".config"])
        #expect(suggestions("~/.c", base: home.url, home: home.url).map(\.name) == [".config"])
    }

    @Test func aMissingFolderGivesNoSuggestions() throws {
        let home = try TempDir()

        #expect(suggestions("~/Nope/", base: home.url, home: home.url).isEmpty)
    }

    @Test func appLibrariesShowUnderTheirFinderNamesAndCompleteToTheirRealPath() throws {
        let home = try TempDir()
        try home.folder("Library/Mobile Documents/com~apple~CloudDocs/Notes")
        try home.folder("Library/Mobile Documents/Numbers/Documents")

        let result = suggestions("~/Library/Mobile Documents/com~apple~CloudDocs/", base: home.url, home: home.url)

        #expect(Set(result.map(\.name)) == ["Notes", "Numbers"])
        let numbers = try #require(result.first { $0.name == "Numbers" })
        #expect(path(numbers.url) == path(home.url.appendingPathComponent("Library/Mobile Documents/Numbers/Documents")))
        #expect(numbers.completion == "~/Library/Mobile Documents/Numbers/Documents/")
        #expect(result.first { $0.name == "Notes" }?.completion
            == "~/Library/Mobile Documents/com~apple~CloudDocs/Notes/")
    }
}
