import Foundation

/// Totals for everything inside a folder, from the last time it was walked.
public struct FolderStats: Sendable, Hashable {
    /// Sum of the files' logical sizes.
    public var bytes: Int64
    /// Space the files take on disk, which differs for compressed, sparse and cloned files.
    public var allocated: Int64
    public var files: Int64
    public var subfolders: Int64
    /// The latest modification of the folder itself or anything inside it.
    public var newest: Date?
    public var calculated: Date
    public var durationMilliseconds: Int64
    /// Some folders inside couldn't be read, so the totals are a lower bound.
    public var incomplete: Bool

    public init(
        bytes: Int64 = 0, allocated: Int64 = 0, files: Int64 = 0, subfolders: Int64 = 0, newest: Date? = nil,
        calculated: Date, durationMilliseconds: Int64 = 0, incomplete: Bool = false
    ) {
        self.bytes = bytes
        self.allocated = allocated
        self.files = files
        self.subfolders = subfolders
        self.newest = newest
        self.calculated = calculated
        self.durationMilliseconds = durationMilliseconds
        self.incomplete = incomplete
    }
}
