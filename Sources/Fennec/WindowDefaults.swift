import Foundation
import FennecCore

@MainActor
enum WindowDefaults {
    private static let defaults = UserDefaults.standard

    static var viewMode: ViewMode {
        get { ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .list }
        set { defaults.set(newValue.rawValue, forKey: "viewMode") }
    }

    static var sortOrder: FennecCore.SortOrder {
        get {
            FennecCore.SortOrder(
                key: SortKey(rawValue: defaults.string(forKey: "sortKey") ?? "") ?? .name,
                ascending: defaults.object(forKey: "sortAscending") as? Bool ?? true)
        }
        set {
            defaults.set(newValue.key.rawValue, forKey: "sortKey")
            defaults.set(newValue.ascending, forKey: "sortAscending")
        }
    }

    static var previewVisible: Bool {
        get { defaults.bool(forKey: "previewVisible") }
        set { defaults.set(newValue, forKey: "previewVisible") }
    }

    static func window(at folder: URL) -> WindowState {
        WindowState(
            frame: nil,
            panes: [PaneState(folder: folder.path, viewMode: viewMode, sortOrder: sortOrder)],
            activePane: 0, otherFolder: nil, splitRatio: 0.5, previewVisible: previewVisible, showHidden: false)
    }
}
