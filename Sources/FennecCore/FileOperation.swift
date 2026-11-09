import Foundation

public enum TransferMode: Sendable, Equatable {
    case copy, move
}

public enum ConflictChoice: Sendable, Equatable {
    case skip, keepBoth, replace
    /// Folders only: combine the contents, asking again for each clashing item inside.
    case merge
}

public struct Conflict: Sendable {
    public let source: URL
    public let existing: URL
    /// True when both the incoming and the existing item are folders, so merging is possible.
    public let isFolder: Bool
}

public typealias ConflictHandler = @Sendable (Conflict) async -> ConflictChoice

public struct OperationProgress: Sendable, Equatable {
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var completedItems: Int
    public var totalItems: Int
    public var currentName: String
}

/// One reversible step of a finished operation. Undo runs them backwards.
public enum UndoStep: Sendable, Equatable {
    case created(URL)
    case moved(from: URL, to: URL)
    case trashed(original: URL, trashed: URL)
    /// An emptied source folder removed after a merge-move; undo recreates it.
    case removedFolder(URL)
}

public struct TransferResult: Sendable {
    public var steps: [UndoStep] = []
    /// The top-level items now in the destination, for selecting them afterwards.
    public var placed: [URL] = []
}

public enum FileOperationError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case alreadyExists(String)
    case intoItself(String)
    case verificationFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "“\(name)” can't be used as a name."
        case .alreadyExists(let name): "An item named “\(name)” already exists here."
        case .intoItself(let name): "“\(name)” can't be moved or copied into itself."
        case .verificationFailed(let name): "The copy of “\(name)” didn't match the original, so the original was kept."
        case .cancelled: "The operation was cancelled."
        }
    }
}

/// Finder's drag rules: same disk moves, another disk copies; Option forces copy, Command forces move.
public enum DropRules {
    public static func mode(sameVolume: Bool, option: Bool, command: Bool) -> TransferMode {
        if option { return .copy }
        if command { return .move }
        return sameVolume ? .move : .copy
    }

    public static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        FileItem.sameVolume(a, b)
    }
}
