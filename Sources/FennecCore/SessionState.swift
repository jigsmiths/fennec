import CoreGraphics
import Foundation

public enum ViewMode: String, Codable, Sendable {
    case list, grid
}

public struct PaneState: Codable, Equatable, Sendable {
    public var folder: String
    public var viewMode: ViewMode
    public var sortOrder: SortOrder

    public init(folder: String, viewMode: ViewMode, sortOrder: SortOrder) {
        self.folder = folder
        self.viewMode = viewMode
        self.sortOrder = sortOrder
    }
}

/// What a window shows: one or two panes side by side, and the window-wide settings.
public struct WindowState: Codable, Equatable, Sendable {
    public static let ratioRange = 0.1...0.9

    public var frame: CGRect?
    /// One pane, or two when split.
    public var panes: [PaneState]
    public var activePane: Int
    /// The folder the second pane showed before the split was closed.
    public var otherFolder: String?
    /// The left pane's share of the width.
    public var splitRatio: Double
    public var previewVisible: Bool
    public var showHidden: Bool

    public init(
        frame: CGRect?, panes: [PaneState], activePane: Int, otherFolder: String?,
        splitRatio: Double, previewVisible: Bool, showHidden: Bool
    ) {
        self.frame = frame
        self.panes = panes
        self.activePane = activePane
        self.otherFolder = otherFolder
        self.splitRatio = splitRatio
        self.previewVisible = previewVisible
        self.showHidden = showHidden
    }

    /// The folder a newly opened second pane shows: where it was last, or else where the active pane is.
    public static func secondPaneFolder(remembered: URL?, active: URL) -> URL {
        if let remembered, isFolder(remembered.path) { return remembered }
        return active
    }

    /// Fixes up a state read from disk: missing folders, too many panes, out-of-range numbers.
    func sanitized(fallback: URL) -> WindowState? {
        guard !panes.isEmpty else { return nil }
        var state = self
        state.panes = Array(panes.prefix(2)).map {
            var pane = $0
            if !Self.isFolder(pane.folder) { pane.folder = fallback.path }
            return pane
        }
        state.activePane = min(max(activePane, 0), state.panes.count - 1)
        if let other = otherFolder, !Self.isFolder(other) { state.otherFolder = nil }
        state.splitRatio = min(max(splitRatio, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
        return state
    }

    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

public struct SessionState: Codable, Equatable, Sendable {
    public var windows: [WindowState]

    public init(windows: [WindowState]) {
        self.windows = windows
    }
}

/// Saves the open windows to a file so a relaunch brings them back, even after a normal quit.
public enum SessionStore {
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Fennec/session.json")
    }

    /// The saved session, or an empty one when the file is missing or unreadable.
    public static func load(from url: URL, fallback: URL) -> SessionState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            return SessionState(windows: [])
        }
        return SessionState(windows: state.windows.compactMap { $0.sanitized(fallback: fallback) })
    }

    public static func save(_ state: SessionState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
