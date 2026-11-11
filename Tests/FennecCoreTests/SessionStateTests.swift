import Foundation
import Testing
@testable import FennecCore

struct SessionStateTests {
    private func window(_ folders: [String], active: Int = 0, other: String? = nil) -> WindowState {
        WindowState(
            frame: CGRect(x: 10, y: 20, width: 1200, height: 720),
            panes: folders.map { PaneState(folder: $0, viewMode: .grid, sortOrder: SortOrder(key: .size, ascending: false)) },
            activePane: active, otherFolder: other, splitRatio: 0.4, previewVisible: true, showHidden: true)
    }

    @Test func roundTripsThroughTheFile() throws {
        let dir = try TempDir()
        try dir.folder("a")
        try dir.folder("b")
        let a = dir.url.appendingPathComponent("a").path
        let b = dir.url.appendingPathComponent("b").path
        let file = dir.url.appendingPathComponent("nested/session.json")
        let state = SessionState(windows: [window([a, b], active: 1), window([a], other: b)])

        try SessionStore.save(state, to: file)
        let loaded = SessionStore.load(from: file, fallback: dir.url)

        #expect(loaded == state)
    }

    @Test func deletedFoldersFallBack() throws {
        let dir = try TempDir()
        try dir.folder("kept")
        let kept = dir.url.appendingPathComponent("kept").path
        let gone = dir.url.appendingPathComponent("gone").path
        let file = dir.url.appendingPathComponent("session.json")
        try SessionStore.save(SessionState(windows: [window([gone, kept], other: gone)]), to: file)

        let loaded = SessionStore.load(from: file, fallback: dir.url)

        #expect(loaded.windows[0].panes.map(\.folder) == [dir.url.path, kept])
        #expect(loaded.windows[0].otherFolder == nil)
    }

    @Test func missingOrDamagedFileStartsFresh() throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("session.json")
        #expect(SessionStore.load(from: file, fallback: dir.url).windows.isEmpty)

        try Data("{not json".utf8).write(to: file)
        #expect(SessionStore.load(from: file, fallback: dir.url).windows.isEmpty)
    }

    @Test func outOfRangeValuesAreClamped() throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("session.json")
        var odd = window([dir.url.path, dir.url.path, dir.url.path], active: 7)
        odd.splitRatio = 3
        try SessionStore.save(SessionState(windows: [odd, window([])]), to: file)

        let loaded = SessionStore.load(from: file, fallback: dir.url)

        #expect(loaded.windows.count == 1)
        #expect(loaded.windows[0].panes.count == 2)
        #expect(loaded.windows[0].activePane == 1)
        #expect(loaded.windows[0].splitRatio == WindowState.ratioRange.upperBound)
    }

    @Test func secondPaneUsesRememberedFolderWhenItStillExists() throws {
        let dir = try TempDir()
        try dir.folder("remembered")
        let remembered = dir.url.appendingPathComponent("remembered")
        let active = dir.url

        #expect(WindowState.secondPaneFolder(remembered: remembered, active: active) == remembered)
        #expect(WindowState.secondPaneFolder(remembered: nil, active: active) == active)
        let gone = dir.url.appendingPathComponent("gone")
        #expect(WindowState.secondPaneFolder(remembered: gone, active: active) == active)
    }
}
