import Foundation

public enum SortKey: String, Sendable, CaseIterable {
    case name, size, modified, kind
}

public struct SortOrder: Sendable, Equatable {
    public var key: SortKey
    public var ascending: Bool

    public init(key: SortKey = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }
}

public enum Sorting {
    /// Folders always come first, whatever the sort direction.
    public static func arrange(_ entries: [FileEntry], showHidden: Bool, order: SortOrder) -> [FileEntry] {
        let visible = showHidden ? entries : entries.filter { !$0.isHidden }
        return sorted(visible, by: order)
    }

    // String.compare(options: .numeric) takes seconds on 50k names, so names are
    // compared as precomputed lowercase UTF-8 bytes and kinds as integer ranks.
    public static func sorted(_ entries: [FileEntry], by order: SortOrder) -> [FileEntry] {
        let names = entries.map { Array($0.name.lowercased().utf8) }
        let kindRanks = order.key == .kind ? kindLabelRanks(entries) : []

        var indices = Array(entries.indices)
        indices.sort { i, j in
            let a = entries[i], b = entries[j]
            if a.isBrowsable != b.isBrowsable { return a.isBrowsable }
            var result: ComparisonResult
            switch order.key {
            case .name: result = .orderedSame
            case .size: result = ordered(a.size ?? -1, b.size ?? -1)
            case .modified: result = ordered(a.modified ?? .distantPast, b.modified ?? .distantPast)
            case .kind: result = ordered(kindRanks[i], kindRanks[j])
            }
            if result == .orderedSame { result = naturalCompare(names[i], names[j]) }
            return order.ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return indices.map { entries[$0] }
    }

    /// Byte-wise compare where digit runs compare by numeric value ("file2" < "file10").
    static func naturalCompare(_ a: [UInt8], _ b: [UInt8]) -> ComparisonResult {
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if isDigit(a[i]), isDigit(b[j]) {
                let (startA, endA) = digitRun(a, from: i)
                let (startB, endB) = digitRun(b, from: j)
                let lengthA = endA - startA, lengthB = endB - startB
                if lengthA != lengthB { return lengthA < lengthB ? .orderedAscending : .orderedDescending }
                for k in 0..<lengthA where a[startA + k] != b[startB + k] {
                    return a[startA + k] < b[startB + k] ? .orderedAscending : .orderedDescending
                }
                i = endA
                j = endB
            } else {
                if a[i] != b[j] { return a[i] < b[j] ? .orderedAscending : .orderedDescending }
                i += 1
                j += 1
            }
        }
        return ordered(a.count - i, b.count - j)
    }

    /// Returns the run's significant digits (leading zeros skipped) and where the run ends.
    private static func digitRun(_ bytes: [UInt8], from index: Int) -> (start: Int, end: Int) {
        var start = index
        while start < bytes.count, bytes[start] == UInt8(ascii: "0") { start += 1 }
        var end = start
        while end < bytes.count, isDigit(bytes[end]) { end += 1 }
        return (start, end)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    /// Ranks each entry by the Kind label the column shows, computing each distinct type's label once.
    private static func kindLabelRanks(_ entries: [FileEntry]) -> [Int] {
        var labelsByType: [String: String] = [:]
        let labels = entries.map { entry in
            let type = entry.isBrowsable ? "folder" : (entry.typeIdentifier ?? "ext:\(entry.url.pathExtension)")
            if let label = labelsByType[type] { return label }
            let label = FileFormatting.kind(for: entry)
            labelsByType[type] = label
            return label
        }
        let sorted = Set(labels).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let rankByLabel = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1, $0) })
        return labels.map { rankByLabel[$0]! }
    }

    private static func ordered<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
