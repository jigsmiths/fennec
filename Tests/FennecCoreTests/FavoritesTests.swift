import Foundation
import Testing
@testable import FennecCore

struct FavoritesTests {
    @Test func addsToTheEndAndSkipsDuplicates() {
        var favorites = Favorites(paths: ["/a"])
        favorites.add(["/b", "/a", "/c/"])
        #expect(favorites.paths == ["/a", "/b", "/c"])
    }

    @Test func addsBeforeAnotherFavoriteInOrder() {
        var favorites = Favorites(paths: ["/a", "/d"])
        favorites.add(["/b", "/c"], before: "/d")
        #expect(favorites.paths == ["/a", "/b", "/c", "/d"])
    }

    @Test func addingBeforeAnUnknownPathAppends() {
        var favorites = Favorites(paths: ["/a"])
        favorites.add(["/b"], before: "/missing")
        #expect(favorites.paths == ["/a", "/b"])
    }

    @Test func normalizesPaths() {
        let favorites = Favorites(paths: ["/a/../b/", "/b"])
        #expect(favorites.paths == ["/b"])
        #expect(favorites.contains("/a/../b"))
    }

    @Test func removes() {
        var favorites = Favorites(paths: ["/a", "/b"])
        favorites.remove("/a/")
        favorites.remove("/missing")
        #expect(favorites.paths == ["/b"])
    }

    @Test func movesUpDownAndToTheEnd() {
        var favorites = Favorites(paths: ["/a", "/b", "/c", "/d"])
        favorites.move("/d", before: "/b")
        #expect(favorites.paths == ["/a", "/d", "/b", "/c"])
        favorites.move("/a", before: "/c")
        #expect(favorites.paths == ["/d", "/b", "/a", "/c"])
        favorites.move("/d", before: nil)
        #expect(favorites.paths == ["/b", "/a", "/c", "/d"])
    }

    @Test func movingOntoItselfOrAnUnpinnedPathDoesNothing() {
        var favorites = Favorites(paths: ["/a", "/b"])
        favorites.move("/a", before: "/a")
        favorites.move("/x", before: "/a")
        #expect(favorites.paths == ["/a", "/b"])
    }

    @Test func roundTripsThroughTheFile() throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("nested/favorites.json")
        let favorites = Favorites(paths: ["/a", "/b"])

        try FavoritesStore.save(favorites, to: file)

        #expect(FavoritesStore.load(from: file) == favorites)
    }

    @Test func missingOrCorruptFileLoadsEmpty() throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("favorites.json")
        #expect(FavoritesStore.load(from: file).paths.isEmpty)

        try Data("not json".utf8).write(to: file)
        #expect(FavoritesStore.load(from: file).paths.isEmpty)
    }
}
