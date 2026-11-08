import Foundation
import UniformTypeIdentifiers

public enum CloudStatus: Sendable, Hashable {
    case none
    case current
    case notDownloaded
}

public struct FileEntry: Sendable, Hashable, Identifiable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    public let size: Int64?
    public let modified: Date?
    public let typeIdentifier: String?
    public let cloudStatus: CloudStatus

    public init(
        url: URL,
        name: String? = nil,
        isDirectory: Bool = false,
        isPackage: Bool = false,
        isHidden: Bool = false,
        size: Int64? = nil,
        modified: Date? = nil,
        typeIdentifier: String? = nil,
        cloudStatus: CloudStatus = .none
    ) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.size = size
        self.modified = modified
        self.typeIdentifier = typeIdentifier
        self.cloudStatus = cloudStatus
    }

    public var id: String { path }
    public var path: String { url.standardizedFileURL.path }

    // Packages such as .app bundles are directories on disk but open like files.
    public var isBrowsable: Bool { isDirectory && !isPackage }

    public var contentType: UTType? { typeIdentifier.flatMap(UTType.init) }
}
