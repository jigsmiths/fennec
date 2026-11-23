import Foundation

public enum StatusText {
    public static func contents(itemCount: Int, selection: [FileEntry]) -> String {
        selection.isEmpty ? "\(itemCount.formatted()) item\(itemCount == 1 ? "" : "s")" : SelectionSummary.describe(selection)
    }

    /// The right side while a folder is being sized, e.g. "Sizing Library · 64% · 3 queued". Without a
    /// previous walk to compare with, it counts files instead of showing a percentage.
    public static func scan(name: String, progress: FolderWalker.Progress, expectedFiles: Int64?, queued: Int) -> String {
        var parts = ["Sizing \(name)"]
        if let fraction = progress.fraction(ofExpected: expectedFiles) {
            parts.append(fraction.formatted(.percent.precision(.fractionLength(0))))
        } else {
            parts.append("\(progress.files.formatted()) file\(progress.files == 1 ? "" : "s")")
        }
        if queued > 0 { parts.append("\(queued.formatted()) queued") }
        return parts.joined(separator: " · ")
    }
}
