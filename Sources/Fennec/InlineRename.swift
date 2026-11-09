import AppKit

/// Edits a name in place in a list cell or grid tile, like Finder: Return commits, Escape cancels,
/// clicking elsewhere commits. The name is selected without its extension.
/// onEnd always runs once: with the new name, or nil when cancelled or unchanged.
@MainActor
final class InlineRename: NSObject, NSTextFieldDelegate {
    private static var active: InlineRename?

    private weak var field: NSTextField?
    private weak var returnFocusTo: NSView?
    private let original: String
    private let onEnd: (String?) -> Void
    private var finished = false

    private init(field: NSTextField, original: String, returnFocusTo: NSView, onEnd: @escaping (String?) -> Void) {
        self.field = field
        self.original = original
        self.returnFocusTo = returnFocusTo
        self.onEnd = onEnd
    }

    static func begin(
        on field: NSTextField, name: String, isFolder: Bool, returnFocusTo: NSView,
        onEnd: @escaping (String?) -> Void
    ) {
        active?.finish(commit: true)
        let rename = InlineRename(field: field, original: name, returnFocusTo: returnFocusTo, onEnd: onEnd)
        active = rename

        field.stringValue = name
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.delegate = rename
        guard field.window?.makeFirstResponder(field) == true else {
            rename.finish(commit: false)
            return
        }
        let base = isFolder ? name : (name as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base.isEmpty ? name : base).utf16.count)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            finish(commit: false)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            finish(commit: true)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finish(commit: true)
    }

    private func finish(commit: Bool) {
        guard !finished, let field else { return }
        finished = true
        let newName = field.stringValue
        field.delegate = nil
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.window?.makeFirstResponder(returnFocusTo)
        if Self.active === self { Self.active = nil }

        if commit, !newName.isEmpty, newName != original {
            onEnd(newName)
        } else {
            field.stringValue = original
            onEnd(nil)
        }
    }
}
