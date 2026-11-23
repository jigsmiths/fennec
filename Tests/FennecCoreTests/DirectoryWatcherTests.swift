import Foundation
import Testing
@testable import FennecCore

@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}

@MainActor
@Suite(.serialized) struct DirectoryWatcherTests {
    @Test func reportsAChangeInTheWatchedFolder() async throws {
        let dir = try TempDir()
        var changes = 0
        let watcher = DirectoryWatcher(url: dir.url) { changes += 1 }
        try Data().write(to: dir.url.appending(path: "a.txt"))
        #expect(try await waitUntil { changes > 0 })
        withExtendedLifetime(watcher) {}
    }

    @Test func staysQuietAfterBeingReleased() async throws {
        let dir = try TempDir()
        var changes = 0
        var watcher: DirectoryWatcher? = DirectoryWatcher(url: dir.url) { changes += 1 }
        _ = watcher
        watcher = nil
        try Data().write(to: dir.url.appending(path: "a.txt"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(changes == 0)
    }
}

@MainActor
@Suite(.serialized) struct TreeWatcherStreamTests {
    @Test func reportsTheChangedSubfolder() async throws {
        let dir = try TempDir()
        let sub = dir.url.appending(path: "sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        var reported: [String] = []
        let watcher = TreeWatcher(url: dir.url) { folders, _ in reported += folders }
        try Data().write(to: sub.appending(path: "a.txt"))
        #expect(try await waitUntil { reported.contains("sub") })
        withExtendedLifetime(watcher) {}
    }

    @Test func staysQuietAfterBeingReleased() async throws {
        let dir = try TempDir()
        var calls = 0
        var watcher: TreeWatcher? = TreeWatcher(url: dir.url) { _, _ in calls += 1 }
        _ = watcher
        watcher = nil
        try Data().write(to: dir.url.appending(path: "a.txt"))
        try await Task.sleep(for: .milliseconds(1000))
        #expect(calls == 0)
    }
}
