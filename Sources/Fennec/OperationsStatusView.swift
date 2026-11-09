import AppKit
import FennecCore

/// The toolbar progress ring for running operations; clicking it lists each job with a cancel button.
@MainActor
final class OperationsStatusView: NSView {
    private let ring = NSProgressIndicator()
    private let button = NSButton()
    private let popover = NSPopover()
    private let list = NSStackView()
    private var timer: Timer?
    private var jobs: [OperationsController.Job] = []
    private var rows: [UUID: (bar: NSProgressIndicator, detail: NSTextField)] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        ring.style = .spinning
        ring.controlSize = .small
        ring.isIndeterminate = false
        ring.minValue = 0
        ring.maxValue = 1

        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(showJobs(_:))
        button.toolTip = "File operations"

        for view in [ring, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        list.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let content = NSViewController()
        content.view = list
        popover.contentViewController = content
        popover.behavior = .transient
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ newJobs: [OperationsController.Job]) {
        jobs = newJobs
        rebuildList()
        if jobs.isEmpty {
            timer?.invalidate()
            timer = nil
            popover.close()
        } else if timer == nil {
            // Progress arrives from the copy thread far more often than it's worth drawing.
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    @objc private func showJobs(_ sender: Any?) {
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    private func rebuildList() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = [:]
        for job in jobs {
            let title = NSTextField(labelWithString: job.title)
            title.lineBreakMode = .byTruncatingMiddle
            let detail = NSTextField(labelWithString: "")
            detail.textColor = .secondaryLabelColor
            detail.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            let cancel = NSButton(
                image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")!,
                target: nil, action: nil)
            cancel.isBordered = false
            cancel.contentTintColor = .secondaryLabelColor
            cancel.toolTip = "Cancel"
            let id = job.id
            cancel.target = self
            cancel.action = #selector(cancelJob(_:))
            cancel.identifier = NSUserInterfaceItemIdentifier(id.uuidString)

            let barRow = NSStackView(views: [bar, cancel])
            let column = NSStackView(views: [title, barRow, detail])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            NSLayoutConstraint.activate([
                column.widthAnchor.constraint(equalToConstant: 320),
                barRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            ])
            list.addArrangedSubview(column)
            rows[id] = (bar, detail)
        }
    }

    @objc private func cancelJob(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        jobs.first { $0.id.uuidString == raw }?.cancel()
    }

    private func refresh() {
        var done: Int64 = 0
        var total: Int64 = 0
        for job in jobs {
            guard let progress = job.progress else { continue }
            done += progress.completedBytes
            total += progress.totalBytes
            let fraction = progress.totalBytes > 0 ? Double(progress.completedBytes) / Double(progress.totalBytes) : 0
            rows[job.id]?.bar.doubleValue = fraction
            rows[job.id]?.detail.stringValue = "\(FileFormatting.bytes(progress.completedBytes)) of "
                + "\(FileFormatting.bytes(progress.totalBytes))  ·  \(progress.currentName)"
        }
        ring.doubleValue = total > 0 ? Double(done) / Double(total) : 0
    }
}
