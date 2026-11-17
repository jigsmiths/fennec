import AppKit
import FennecCore

/// The strip under the panes: what the active folder holds or what's selected on the left, and any folder
/// sizing that has been running for a while on the right. Clicking that lists the walk and its queue.
@MainActor
final class StatusBarView: NSView {
    static let height: CGFloat = 24
    /// Most walks finish in a blink; only ones that run longer than this are worth showing.
    private static let showScansAfter = Duration.seconds(1)
    private static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    private let contentsLabel = NSTextField(labelWithString: "")
    private let scanButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let popover = NSPopover()
    private let scansList = ScansListController()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let separator = NSBox()
        separator.boxType = .separator

        contentsLabel.font = Self.font
        contentsLabel.textColor = .secondaryLabelColor
        contentsLabel.lineBreakMode = .byTruncatingTail
        contentsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scanButton.isBordered = false
        scanButton.font = Self.font
        scanButton.contentTintColor = .secondaryLabelColor
        scanButton.lineBreakMode = .byTruncatingMiddle
        scanButton.target = self
        scanButton.action = #selector(showScans(_:))
        scanButton.toolTip = "Folder sizes being calculated"
        scanButton.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.minValue = 0
        spinner.maxValue = 1

        popover.contentViewController = scansList
        popover.behavior = .transient

        for view in [separator, contentsLabel, spinner, scanButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentsLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.leadingAnchor.constraint(greaterThanOrEqualTo: contentsLabel.trailingAnchor, constant: 16),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            scanButton.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            scanButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scanButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(activityChanged(_:)), name: FolderStatsService.activityDidChange, object: nil)
        updateScan()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func showContents(itemCount: Int, selection: [FileEntry]) {
        contentsLabel.stringValue = StatusText.contents(itemCount: itemCount, selection: selection)
    }

    @objc private func activityChanged(_ notification: Notification) {
        updateScan()
    }

    private func updateScan() {
        let service = FolderStatsService.shared
        if popover.isShown { scansList.show(current: service.current, queued: service.queued) }
        // Once showing, keep going until the queue is done, so short walks after a long one don't blink.
        let showing = !scanButton.isHidden
        guard let scan = service.current, showing || scan.started.duration(to: .now) > Self.showScansAfter else {
            if !showing || service.queued.isEmpty { hideScan() }
            return
        }

        scanButton.isHidden = false
        spinner.isHidden = false
        scanButton.title = StatusText.scan(
            name: FileManager.default.displayName(atPath: scan.url.path), progress: scan.progress,
            expectedFiles: scan.expectedFiles, queued: service.queued.count)
        if let fraction = scan.fraction {
            spinner.stopAnimation(nil)
            spinner.isIndeterminate = false
            spinner.doubleValue = fraction
        } else {
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
        }
    }

    private func hideScan() {
        scanButton.isHidden = true
        spinner.isHidden = true
        spinner.stopAnimation(nil)
        if popover.isShown, FolderStatsService.shared.current == nil { popover.close() }
    }

    @objc private func showScans(_ sender: Any?) {
        let service = FolderStatsService.shared
        scansList.show(current: service.current, queued: service.queued)
        popover.show(relativeTo: scanButton.bounds, of: scanButton, preferredEdge: .maxY)
    }
}

/// The popover listing the walk in progress and the folders waiting, each with a Cancel button.
@MainActor
private final class ScansListController: NSViewController {
    private static let shownQueue = 8
    private let stack = NSStackView()
    /// The paths the rows were built for, so progress updates only change text.
    private var builtFor: [String] = []
    private var currentDetail: NSTextField?

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view = stack
    }

    func show(current: FolderStatsService.Scan?, queued: [URL]) {
        loadViewIfNeeded()
        let paths = ([current?.url].compactMap { $0 } + queued.prefix(Self.shownQueue)).map(\.path) + ["\(queued.count)"]
        if paths != builtFor {
            builtFor = paths
            rebuild(current: current, queued: queued)
        }
        if let current { currentDetail?.stringValue = Self.detail(current) }
    }

    private func rebuild(current: FolderStatsService.Scan?, queued: [URL]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        currentDetail = nil
        if let current {
            let detail = Self.label(Self.detail(current), secondary: true)
            currentDetail = detail
            stack.addArrangedSubview(row(current.url, detail: detail))
        }
        if !queued.isEmpty {
            stack.addArrangedSubview(Self.label("Waiting", secondary: true))
            for url in queued.prefix(Self.shownQueue) { stack.addArrangedSubview(row(url, detail: nil)) }
            if queued.count > Self.shownQueue {
                stack.addArrangedSubview(Self.label("and \(queued.count - Self.shownQueue) more", secondary: true))
            }
        }
        if current == nil, queued.isEmpty { stack.addArrangedSubview(Self.label("Nothing being sized", secondary: true)) }
    }

    private func row(_ url: URL, detail: NSTextField?) -> NSView {
        let name = Self.label(FileManager.default.displayName(atPath: url.path), secondary: false)
        name.toolTip = url.path
        let text = NSStackView(views: [name] + [detail].compactMap { $0 })
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let cancel = ClosureButton(title: "Cancel") { FolderStatsService.shared.cancel(url) }
        cancel.controlSize = .small
        cancel.bezelStyle = .rounded
        let row = NSStackView(views: [text, cancel])
        row.spacing = 16
        text.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return row
    }

    private static func detail(_ scan: FolderStatsService.Scan) -> String {
        var parts = ["\(scan.progress.files.formatted()) files", FileFormatting.bytes(scan.progress.bytes)]
        if let fraction = scan.fraction { parts.append(fraction.formatted(.percent.precision(.fractionLength(0)))) }
        if !scan.progress.folder.isEmpty { parts.append("in \(scan.progress.folder)") }
        return parts.joined(separator: " · ")
    }

    private static func label(_ text: String, secondary: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: secondary ? NSFont.smallSystemFontSize : NSFont.systemFontSize)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}

private final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        target = self
        action = #selector(run(_:))
    }

    @objc private func run(_ sender: Any?) { handler?() }
}

/// The panes with the status bar along their bottom edge. Its view loads with the window's, after the panes
/// have their split items: loading a split view controller's view before that throws.
@MainActor
final class PanesContainer: NSViewController {
    private let panes: NSViewController
    private let statusBar: StatusBarView

    init(_ panes: NSViewController, statusBar: StatusBarView) {
        self.panes = panes
        self.statusBar = statusBar
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSView()
        addChild(panes)
        for child in [panes.view, statusBar] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            panes.view.topAnchor.constraint(equalTo: view.topAnchor),
            panes.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panes.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panes.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
