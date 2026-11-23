/// Turns a menu key equivalent into the label macOS shows for it, like "⇧⌘C".
public enum ShortcutLabel {
    /// Raw values follow the order macOS shows modifiers in.
    public enum Modifier: Int, CaseIterable, Comparable, Sendable {
        case control, option, shift, command

        public var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }

        public static func < (lhs: Modifier, rhs: Modifier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public static func text(key: String, modifiers: Set<Modifier>) -> String {
        let prefix = modifiers.sorted().map(\.symbol).joined()
        return prefix + keySymbol(key)
    }

    static func keySymbol(_ key: String) -> String {
        switch key {
        case "\u{F700}": "↑"
        case "\u{F701}": "↓"
        case "\u{F702}": "←"
        case "\u{F703}": "→"
        case "\u{8}", "\u{7F}": "⌫"
        case "\u{F728}": "⌦"
        case "\r", "\u{3}": "↩"
        case "\t": "⇥"
        case " ": "Space"
        case "\u{1B}": "⎋"
        default: key.uppercased()
        }
    }
}
