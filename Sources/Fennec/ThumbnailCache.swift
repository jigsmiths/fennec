import AppKit
import FennecCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Image, PDF and video thumbnails, generated off the main thread and cached by path and modified date.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 2000
    }

    func thumbnail(for entry: FileEntry, size: CGFloat, completion: @escaping @MainActor @Sendable (NSImage) -> Void) {
        guard Self.wantsThumbnail(entry) else { return }
        let key = "\(entry.path)|\(entry.modified?.timeIntervalSince1970 ?? 0)|\(Int(size))"
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: entry.url, size: CGSize(width: size, height: size),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let cgImage = representation?.cgImage else { return }
            Task { @MainActor in
                let image = NSImage(cgImage: cgImage, size: .zero)
                self?.cache.setObject(image, forKey: key as NSString)
                completion(image)
            }
        }
    }

    // Cloud-only files are skipped: generating a thumbnail would download them.
    private static func wantsThumbnail(_ entry: FileEntry) -> Bool {
        guard !entry.isDirectory, entry.cloudStatus != .notDownloaded, let type = entry.contentType else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie)
    }
}
