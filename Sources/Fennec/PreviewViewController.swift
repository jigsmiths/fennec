import AppKit
import FennecCore
import Quartz

/// The preview pane: a Quick Look preview of the selected file plus its details.
@MainActor
final class PreviewViewController: NSViewController {
    var showHidden = false

    private let preview: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
    private let bigIcon = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private var pendingRender: Task<Void, Never>?
    private var folderCount: Task<Void, Never>?

    override func loadView() {
        preview.shouldCloseWithWindow = true
        bigIcon.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        nameLabel.alignment = .center
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.alignment = .center

        let stack = NSStackView(views: [preview, bigIcon, nameLabel, detailsLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        // Starting width for the pane; the split view's autosave keeps the user's width after that.
        let preferredWidth = container.widthAnchor.constraint(equalToConstant: 300)
        preferredWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            preferredWidth,
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalTo: container.heightAnchor, multiplier: 0.6),
            bigIcon.widthAnchor.constraint(equalToConstant: 128),
            bigIcon.heightAnchor.constraint(equalToConstant: 128),
            nameLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = container
        render([])
    }

    /// Waits briefly so arrowing through a folder doesn't load a preview for every row passed.
    func show(_ entries: [FileEntry]) {
        pendingRender?.cancel()
        pendingRender = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.render(entries)
        }
    }

    private func render(_ entries: [FileEntry]) {
        loadViewIfNeeded()
        folderCount?.cancel()

        guard let entry = entries.first else {
            showIcon(nil)
            nameLabel.stringValue = ""
            detailsLabel.stringValue = "No selection"
            return
        }
        if entries.count > 1 {
            showIcon(NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil))
            nameLabel.stringValue = ""
            detailsLabel.stringValue = SelectionSummary.describe(entries)
            return
        }

        nameLabel.stringValue = entry.name
        let modified = entry.modified.map { "Modified \(FileDisplay.date($0))" }
        detailsLabel.stringValue = [FileDisplay.kind(for: entry), FileDisplay.size(for: entry), modified ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        if entry.isBrowsable {
            showIcon(FileDisplay.icon(for: entry))
            countItems(in: entry.url)
        } else if entry.cloudStatus == .notDownloaded {
            // Previewing would download the file, so only say where it is.
            showIcon(FileDisplay.icon(for: entry))
            detailsLabel.stringValue += "\nIn iCloud, not downloaded"
        } else {
            bigIcon.isHidden = true
            preview.isHidden = false
            preview.previewItem = entry.url as NSURL
        }
    }

    private func showIcon(_ image: NSImage?) {
        preview.previewItem = nil
        preview.isHidden = true
        bigIcon.image = image
        bigIcon.isHidden = image == nil
    }

    private func countItems(in url: URL) {
        let includeHidden = showHidden
        folderCount = Task { [weak self] in
            let count = await Task.detached(priority: .utility) {
                DirectoryLoader.itemCount(at: url, includeHidden: includeHidden)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.detailsLabel.stringValue = "Folder\n\(count) item\(count == 1 ? "" : "s")"
        }
    }
}
