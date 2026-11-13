import Testing
@testable import FennecCore

@Suite struct FuzzyMatcherTests {
    private func match(_ query: String, _ text: String) -> FuzzyMatcher.Match? {
        FuzzyMatcher.match(FuzzyMatcher.Query(query), FuzzyMatcher.Candidate(text))
    }

    private func ranked(_ query: String, _ texts: [String]) -> [String] {
        let candidates = texts.map(FuzzyMatcher.Candidate.init)
        return FuzzyMatcher.rank(FuzzyMatcher.Query(query), in: candidates, limit: 100).map { texts[$0.index] }
    }

    @Test func matchesASubsequenceIgnoringCase() {
        #expect(match("fvc", "Sources/FolderViewController.swift") != nil)
        #expect(match("FOLDER", "Sources/folder.swift") != nil)
        #expect(match("xyz", "Sources/folder.swift") == nil)
        #expect(match("dlo", "old") == nil)
    }

    @Test func reportsMatchedPositions() throws {
        let result = try #require(match("abc", "a/b/c"))
        #expect(result.positions == [0, 2, 4])
    }

    @Test func prefersTheFilenameOverTheDirectory() throws {
        let result = try #require(match("main", "main/x/main.swift"))
        #expect(result.positions == [7, 8, 9, 10])
    }

    @Test func spaceSeparatedTermsMustAllMatch() {
        #expect(match("src swift", "src/app/main.swift") != nil)
        #expect(match("src rust", "src/app/main.swift") == nil)
    }

    @Test func emptyQueryMatchesEverythingInOrder() {
        #expect(ranked("", ["b", "a", "c"]) == ["b", "a", "c"])
        #expect(ranked("   ", ["b", "a"]) == ["b", "a"])
    }

    @Test func ranksConsecutiveMatchesFirst() {
        #expect(ranked("main", ["m/a/i/n.txt", "app/main.swift"]).first == "app/main.swift")
    }

    @Test func ranksWordStartsAboveMidWordMatches() {
        #expect(ranked("fvc", ["docs/favicon.ico", "FolderViewController.swift"]).first == "FolderViewController.swift")
        #expect(ranked("rd", ["breadcrumbs.txt", "read_data.py"]).first == "read_data.py")
    }

    @Test func ranksFilenameMatchesAboveDirectoryMatches() {
        #expect(ranked("test", ["Tests/Fixtures/a.json", "src/test.swift"]).first == "src/test.swift")
    }

    @Test func breaksTiesWithShorterPaths() {
        #expect(ranked("readme", ["docs/old/README.md", "README.md"]) == ["README.md", "docs/old/README.md"])
    }

    // MARK: search

    /// Paths with lots of overlap, so most queries match many of them.
    private static let corpus: [FuzzyMatcher.Candidate] = (0..<30_000).map { i in
        let folders = ["src", "Sources/Fennec", "docs/guides", "Tests/FennecCoreTests", "node/lib", "assets/img"]
        let names = ["main", "Folder", "readme", "FileFinder", "index", "Matcher", "utils", "config"]
        let exts = ["swift", "md", "json", "ts", "png"]
        return .init("\(folders[i % 6])/\(i % 97)/\(names[i % 8])\(i).\(exts[i % 5])")
    }

    private func signature(_ result: FuzzyMatcher.SearchResult) -> [String] {
        result.top.map { "\($0.index):\($0.match.score):\($0.match.positions)" }
    }

    @Test func searchMatchesAFullSortAcrossChunks() {
        let query = FuzzyMatcher.Query("src ma")
        let everything = FuzzyMatcher.search(query, in: Self.corpus, limit: Self.corpus.count)
        let top = FuzzyMatcher.search(query, in: Self.corpus, limit: 25)

        #expect(everything.matchCount > 1000)
        #expect(top.matchCount == everything.matchCount)
        #expect(signature(top) == Array(signature(everything).prefix(25)))
    }

    @Test func narrowingAPreviousSearchGivesTheSameResults() {
        var previous: FuzzyMatcher.SearchState?
        for typed in ["f", "fi", "fil", "file", "file m", "file ma"] {
            let narrowed = FuzzyMatcher.search(.init(typed), in: Self.corpus, limit: 50, after: previous)
            let fresh = FuzzyMatcher.search(.init(typed), in: Self.corpus, limit: 50)
            #expect(signature(narrowed) == signature(fresh), "query \(typed)")
            #expect(narrowed.matchCount == fresh.matchCount, "query \(typed)")
            previous = narrowed.state
        }
    }

    @Test func narrowingIncludesCandidatesAddedSinceThePreviousSearch() {
        let first = Array(Self.corpus.prefix(10_000))
        let previous = FuzzyMatcher.search(.init("read"), in: first, limit: 50)
        let narrowed = FuzzyMatcher.search(.init("readme"), in: Self.corpus, limit: 50, after: previous.state)
        let fresh = FuzzyMatcher.search(.init("readme"), in: Self.corpus, limit: 50)

        #expect(signature(narrowed) == signature(fresh))
        #expect(narrowed.matchCount == fresh.matchCount)
    }

    @Test func aQueryThatIsNotAnExtensionSearchesEverythingAgain() {
        let previous = FuzzyMatcher.search(.init("readme"), in: Self.corpus, limit: 50)
        for typed in ["read", "main", "readmx"] {
            let after = FuzzyMatcher.search(.init(typed), in: Self.corpus, limit: 50, after: previous.state)
            let fresh = FuzzyMatcher.search(.init(typed), in: Self.corpus, limit: 50)
            #expect(signature(after) == signature(fresh), "query \(typed)")
        }
    }

    @Test func emptySearchCountsEverything() {
        let result = FuzzyMatcher.search(.init(""), in: Self.corpus, limit: 10)
        #expect(result.top.map(\.index) == Array(0..<10))
        #expect(result.matchCount == Self.corpus.count)
    }

    // MARK: scoped search

    private static let prefix = "home/me/"
    /// The corpus under `prefix`, interleaved with the same paths under another folder that's out of scope.
    private static let homeCorpus: [FuzzyMatcher.Candidate] = corpus.flatMap { candidate in
        [FuzzyMatcher.Candidate(prefix + candidate.text), FuzzyMatcher.Candidate("other/" + candidate.text)]
    }
    private static let homeScope = FuzzyMatcher.Scope(
        indices: Array(stride(from: 0, to: homeCorpus.count, by: 2)), skip: prefix.utf16.count)

    /// Results as (index into `corpus`, score, positions relative to the scope).
    private func scopedSignature(_ result: FuzzyMatcher.SearchResult) -> [String] {
        let skip = Self.homeScope.skip
        return result.top.map { "\($0.index / 2):\($0.match.score):\($0.match.positions.map { $0 - skip })" }
    }

    @Test func scopedSearchRanksLikeASearchWithoutThePrefix() {
        for typed in ["readme", "src ma", "fvc", "Sources/Fennec"] {
            let scoped = FuzzyMatcher.search(.init(typed), in: Self.homeCorpus, limit: 40, scope: Self.homeScope)
            let plain = FuzzyMatcher.search(.init(typed), in: Self.corpus, limit: 40)
            #expect(scopedSignature(scoped) == signature(plain), "query \(typed)")
            #expect(scoped.matchCount == plain.matchCount, "query \(typed)")
        }
    }

    @Test func theScopePrefixIsNotMatched() {
        let candidates = [FuzzyMatcher.Candidate("src/personal/notes.txt")]
        let scope = FuzzyMatcher.Scope(indices: [0], skip: "src/personal/".utf16.count)

        #expect(FuzzyMatcher.search(.init("src"), in: candidates, limit: 10, scope: scope).top.isEmpty)
        #expect(FuzzyMatcher.search(.init("pers"), in: candidates, limit: 10, scope: scope).top.isEmpty)
        #expect(FuzzyMatcher.search(.init("notes"), in: candidates, limit: 10, scope: scope).top.count == 1)
    }

    @Test func scopedNarrowingIncludesItemsAddedSinceThePreviousSearch() {
        let firstPart = Array(Self.homeCorpus.prefix(20_000))
        let firstScope = FuzzyMatcher.Scope(indices: Self.homeScope.indices.filter { $0 < 20_000 }, skip: Self.homeScope.skip)
        let previous = FuzzyMatcher.search(.init("read"), in: firstPart, limit: 40, scope: firstScope)
        let narrowed = FuzzyMatcher.search(
            .init("readme"), in: Self.homeCorpus, limit: 40, after: previous.state, scope: Self.homeScope)
        let fresh = FuzzyMatcher.search(.init("readme"), in: Self.homeCorpus, limit: 40, scope: Self.homeScope)

        #expect(scopedSignature(narrowed) == scopedSignature(fresh))
        #expect(narrowed.matchCount == fresh.matchCount)
    }

    @Test func emptyScopedSearchListsTheScopeInOrder() {
        let result = FuzzyMatcher.search(.init(""), in: Self.homeCorpus, limit: 3, scope: Self.homeScope)
        #expect(result.top.map(\.index) == [0, 2, 4])
        #expect(result.matchCount == Self.corpus.count)
    }

    @Test func respectsTheLimit() {
        let texts = (0..<50).map { "file\($0).txt" }
        #expect(ranked("file", texts).count == 50)
        let candidates = texts.map(FuzzyMatcher.Candidate.init)
        #expect(FuzzyMatcher.rank(FuzzyMatcher.Query("file"), in: candidates, limit: 10).count == 10)
    }
}
