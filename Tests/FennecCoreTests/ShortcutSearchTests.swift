import Testing
@testable import FennecCore

@Suite struct ShortcutSearchTests {
    private func matches(_ query: String, _ name: String = "Copy Path", _ keys: String = "⇧⌘C") -> Bool {
        ShortcutSearch.matches(query: query, name: name, keys: keys)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(matches(""))
        #expect(matches("   "))
    }

    @Test func matchesCommandNameIgnoringCase() {
        #expect(matches("split", "Split Panes", "⌘\\"))
        #expect(matches("TRASH", "Move to Trash", "⌘⌫"))
        #expect(!matches("rename", "Move to Trash", "⌘⌫"))
    }

    @Test func symbolQueryMatchesInAnyModifierOrder() {
        #expect(matches("⇧⌘C"))
        #expect(matches("⌘⇧C"))
        #expect(matches("⌘⇧c"))
    }

    @Test func typedWordsMatchTheSymbols() {
        #expect(matches("cmd shift c"))
        #expect(matches("command shift c"))
        #expect(matches("cmd+shift+c"))
        #expect(matches("opt", "Go Back", "⌥⌘←"))
        #expect(matches("alt cmd left", "Go Back", "⌥⌘←"))
        #expect(matches("ctrl", "Zoom", "⌃⌘Z"))
        #expect(matches("control cmd z", "Zoom", "⌃⌘Z"))
    }

    @Test func modifiersAloneFindEveryShortcutUsingThem() {
        #expect(matches("cmd"))
        #expect(matches("cmd shift"))
        #expect(!matches("ctrl"))
    }

    @Test func wrongKeyOrMissingModifierDoesNotMatch() {
        #expect(!matches("cmd shift x"))
        #expect(!matches("opt cmd c"))
        #expect(!matches("cmd c", "Copy", "⌘V"))
    }

    @Test func anyAlternativeCanMatch() {
        #expect(matches("cmd down", "Open", "⌘O or ⌘↓"))
        #expect(matches("⌘O", "Open", "⌘O or ⌘↓"))
    }

    @Test func namedKeysMatchTheirSymbols() {
        #expect(matches("tab", "Switch pane", "⇥"))
        #expect(matches("space", "Quick Look", "Space"))
        #expect(matches("return", "Rename", "↩"))
        #expect(matches("cmd backspace", "Move to Trash", "⌘⌫"))
    }

    @Test func punctuationKeysMatch() {
        #expect(matches("cmd \\", "Split Panes", "⌘\\"))
        #expect(matches("cmd +", "Zoom In", "⌘+"))
        #expect(matches("cmd /", "Keyboard Shortcuts", "⌘/"))
    }

    @Test func textLabelsMatchAsText() {
        #expect(matches("opt", "Copy instead of move", "⌥ while dragging"))
        #expect(matches("drag", "Copy instead of move", "⌥ while dragging"))
        #expect(matches("double", "Even out the panes", "Double-click the divider"))
    }

    @Test func unrecognisedWordsOnlyMatchByName() {
        #expect(!matches("banana"))
    }
}
