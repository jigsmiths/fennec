import Foundation

/// Decides whether a row in the shortcuts panel matches what the user typed, by command name or by keys.
public enum ShortcutSearch {
    public typealias Modifier = ShortcutLabel.Modifier

    /// `keys` is the label shown in the panel, like "⇧⌘C" or "⌘O or ⌘↓".
    public static func matches(query: String, name: String, keys: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty || name.localizedCaseInsensitiveContains(query) { return true }
        let wanted = Shortcut(query: query)
        return keys.components(separatedBy: " or ").contains { label in
            if label.localizedCaseInsensitiveContains(query) { return true }
            guard let wanted else { return false }
            return wanted.isPart(of: Shortcut(label: label))
        }
    }

    struct Shortcut {
        var modifiers: Set<Modifier> = []
        var key: String?

        /// Parses a panel label: leading modifier symbols, then the key (or free text like "while dragging").
        init(label: String) {
            var rest = Substring(label)
            while let first = rest.first, let modifier = Self.modifier(symbol: first) {
                modifiers.insert(modifier)
                rest = rest.dropFirst()
            }
            let key = rest.trimmingCharacters(in: .whitespaces)
            self.key = key.isEmpty ? nil : key.uppercased()
        }

        /// Parses typed input like "cmd shift c", "cmd+c" or "⌘⇧C". Nil when it doesn't read as a shortcut.
        init?(query: String) {
            for token in Self.tokens(query) {
                var rest = Substring(token)
                while let first = rest.first, let modifier = Self.modifier(symbol: first) {
                    modifiers.insert(modifier)
                    rest = rest.dropFirst()
                }
                if rest.isEmpty { continue }
                if let modifier = Self.modifierWords[rest.lowercased()] {
                    modifiers.insert(modifier)
                    continue
                }
                let key: String
                if let named = Self.keyWords[rest.lowercased()] {
                    key = named
                } else if rest.count == 1 {
                    key = rest.uppercased()
                } else {
                    return nil
                }
                if self.key != nil { return nil }
                self.key = key
            }
            if modifiers.isEmpty && key == nil { return nil }
        }

        func isPart(of other: Shortcut) -> Bool {
            modifiers.isSubset(of: other.modifiers) && (key == nil || key == other.key)
        }

        /// Splits on spaces and "+", keeping a lone "+" as the key itself.
        private static func tokens(_ query: String) -> [String] {
            query.split(whereSeparator: \.isWhitespace).flatMap { word -> [String] in
                word == "+" ? ["+"] : word.split(separator: "+").map(String.init)
            }
        }

        private static func modifier(symbol: Character) -> Modifier? {
            Modifier.allCases.first { $0.symbol == String(symbol) }
        }

        private static let modifierWords: [String: Modifier] = [
            "cmd": .command, "command": .command,
            "shift": .shift,
            "opt": .option, "option": .option, "alt": .option,
            "ctrl": .control, "control": .control,
        ]

        // Values match what ShortcutLabel shows, uppercased.
        private static let keyWords: [String: String] = [
            "up": "↑", "down": "↓", "left": "←", "right": "→",
            "return": "↩", "enter": "↩", "tab": "⇥", "space": "SPACE",
            "delete": "⌫", "backspace": "⌫", "esc": "⎋", "escape": "⎋",
        ]
    }
}
