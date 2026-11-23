import FennecCore

enum KeyCode {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let enter: UInt16 = 76
}

/// Unmodified keys the file list and grid handle themselves, and their rows in the shortcuts panel.
enum FolderKey: CaseIterable {
    case rename, quickLook, switchPane

    init?(keyCode: UInt16) {
        guard let key = Self.allCases.first(where: { $0.keyCodes.contains(keyCode) }) else { return nil }
        self = key
    }

    var keyCodes: [UInt16] {
        switch self {
        case .rename: [KeyCode.returnKey, KeyCode.enter]
        case .quickLook: [KeyCode.space]
        case .switchPane: [KeyCode.tab]
        }
    }

    var shortcut: (name: String, keys: String) {
        switch self {
        case .rename: ("Rename", ShortcutLabel.text(key: "\r", modifiers: []))
        case .quickLook: ("Quick Look", ShortcutLabel.text(key: " ", modifiers: []))
        case .switchPane: ("Switch pane", ShortcutLabel.text(key: "\t", modifiers: []))
        }
    }
}
