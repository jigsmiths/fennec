import Testing
@testable import FennecCore

@Suite struct ShortcutLabelTests {
    @Test func lettersAreUppercasedAfterTheModifiers() {
        #expect(ShortcutLabel.text(key: "c", modifiers: [.command]) == "⌘C")
        #expect(ShortcutLabel.text(key: "c", modifiers: [.command, .shift]) == "⇧⌘C")
    }

    @Test func modifiersUseTheStandardMacOrder() {
        #expect(ShortcutLabel.text(key: "s", modifiers: [.command, .control, .shift, .option]) == "⌃⌥⇧⌘S")
    }

    @Test func specialKeysUseTheirSymbols() {
        #expect(ShortcutLabel.text(key: "\u{F700}", modifiers: [.command]) == "⌘↑")
        #expect(ShortcutLabel.text(key: "\u{F701}", modifiers: [.command]) == "⌘↓")
        #expect(ShortcutLabel.text(key: "\u{8}", modifiers: [.command, .option]) == "⌥⌘⌫")
        #expect(ShortcutLabel.text(key: "\r", modifiers: []) == "↩")
        #expect(ShortcutLabel.text(key: "\t", modifiers: []) == "⇥")
        #expect(ShortcutLabel.text(key: " ", modifiers: []) == "Space")
        #expect(ShortcutLabel.text(key: "\u{1B}", modifiers: []) == "⎋")
    }

    @Test func punctuationIsKeptAsIs() {
        #expect(ShortcutLabel.text(key: ".", modifiers: [.command, .shift]) == "⇧⌘.")
        #expect(ShortcutLabel.text(key: "[", modifiers: [.command]) == "⌘[")
    }
}
