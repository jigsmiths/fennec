import AppKit

@MainActor
final class PathBarView: NSView {
    var onNavigate: ((URL) -> Void)?

    private let stack = NSStackView()
    private var segmentURLs: [URL] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ url: URL) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let segments = Self.segments(for: url)
        segmentURLs = segments.map(\.url)

        for (index, segment) in segments.enumerated() {
            if index > 0 {
                let chevron = NSTextField(labelWithString: "›")
                chevron.textColor = .tertiaryLabelColor
                stack.addArrangedSubview(chevron)
            }
            let button = NSButton(title: segment.name, target: self, action: #selector(segmentClicked(_:)))
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.tag = index
            button.lineBreakMode = .byTruncatingMiddle
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if let symbol = segment.symbol {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                button.imagePosition = .imageLeading
            }
            if index == segments.count - 1 {
                button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            }
            stack.addArrangedSubview(button)
        }
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        onNavigate?(segmentURLs[sender.tag])
    }

    struct Segment {
        let name: String
        let symbol: String?
        let url: URL
    }

    static func segments(for url: URL) -> [Segment] {
        let path = url.standardizedFileURL.path
        let anchor = anchor(for: path)
        var segments = [anchor]
        let rest = path.dropFirst(anchor.url.standardizedFileURL.path.count)
        var current = anchor.url
        for component in rest.split(separator: "/") {
            current = current.appendingPathComponent(String(component), isDirectory: true)
            segments.append(Segment(name: String(component), symbol: nil, url: current))
        }
        return segments
    }

    private static func anchor(for path: String) -> Segment {
        let named: [(URL, String, String)] = [
            (Places.iCloudDrive, "iCloud Drive", "icloud"),
            (Places.home, "Home", "house"),
        ]
        for (url, name, symbol) in named {
            let root = url.standardizedFileURL.path
            if path == root || path.hasPrefix(root + "/") {
                return Segment(name: name, symbol: symbol, url: url)
            }
        }
        let parts = path.split(separator: "/")
        if parts.count >= 2, parts[0] == "Volumes" {
            return Segment(name: String(parts[1]), symbol: "externaldrive",
                           url: URL(filePath: "/Volumes/\(parts[1])", directoryHint: .isDirectory))
        }
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        let name = (try? root.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "/"
        return Segment(name: name, symbol: "internaldrive", url: root)
    }
}
