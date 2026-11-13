import Testing
@testable import FennecCore

@Suite struct TreeWatcherTests {
    @Test func mapsEventPathsToFoldersRelativeToTheRoot() {
        #expect(TreeWatcher.relativeFolder("/a/b", under: "/a/b") == "")
        #expect(TreeWatcher.relativeFolder("/a/b/", under: "/a/b") == "")
        #expect(TreeWatcher.relativeFolder("/a/b/c/d/", under: "/a/b") == "c/d")
        #expect(TreeWatcher.relativeFolder("/a/b/c", under: "/a/b") == "c")
    }

    @Test func ignoresPathsOutsideTheRoot() {
        #expect(TreeWatcher.relativeFolder("/a/bc", under: "/a/b") == nil)
        #expect(TreeWatcher.relativeFolder("/a", under: "/a/b") == nil)
        #expect(TreeWatcher.relativeFolder("/x/y", under: "/a/b") == nil)
    }

    @Test func handlesTheFilesystemRoot() {
        #expect(TreeWatcher.relativeFolder("/", under: "/") == "")
        #expect(TreeWatcher.relativeFolder("/Users/me/", under: "/") == "Users/me")
    }
}
