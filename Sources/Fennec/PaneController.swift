import AppKit
import FennecCore

/// One pane: a header with back, forward and the path, above a folder view. Each pane has its own history.
@MainActor
final class PaneController: NSViewController {
    let folder: FolderViewController
    private(set) var history: NavigationHistory

    /// The pane was clicked, focused or navigated from its header, so it should become the active pane.
    var onActivate: (() -> Void)?
    /// The pane now shows a different folder.
    var onNavigate: (() -> Void)?

    var isActive = false {
        didSet { updateHeader() }
    }

    var currentFolder: URL { history.current }

    private let header = PaneHeaderView()
    private let pathBar = PathBarView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()

    init(state: PaneState, showHidden: Bool) {
        let start = URL(filePath: state.folder, directoryHint: .isDirectory)
        history = NavigationHistory(start: start)
        folder = FolderViewController(viewMode: state.viewMode, sortOrder: state.sortOrder, showHidden: showHidden)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var state: PaneState {
        PaneState(folder: currentFolder.path, viewMode: folder.viewMode, sortOrder: folder.sortOrder)
    }

    override func loadView() {
        let container = NSView()
        container.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for (button, symbol, label, action) in [
            (backButton, "chevron.left", "Back", #selector(goBack)),
            (forwardButton, "chevron.right", "Forward", #selector(goForward)),
        ] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.toolTip = label
            button.target = self
            button.action = action
            button.refusesFirstResponder = true
        }
        pathBar.onNavigate = { [weak self] url in
            self?.onActivate?()
            self?.navigate(to: url)
        }

        let stack = NSStackView(views: [backButton, forwardButton, pathBar])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        pathBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        header.onClick = { [weak self] in self?.onActivate?() }
        header.wantsLayer = true
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        header.addSubview(separator)
        container.addSubview(header)

        addChild(folder)
        folder.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(folder.view)

        NSLayoutConstraint.activate([
            // Below the toolbar, which the window's full-size content view would otherwise put on top of it.
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: 24),
            separator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            folder.view.topAnchor.constraint(equalTo: header.bottomAnchor),
            folder.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            folder.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            folder.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        updateHeader()
    }

    // MARK: Navigation

    func navigate(to url: URL, selecting selection: URL? = nil) {
        history.visit(url)
        show(history.current, selecting: selection)
    }

    /// Loads the starting folder; called once the pane is on screen.
    func showCurrent() {
        show(history.current, selecting: nil)
    }

    @objc func goBack() {
        onActivate?()
        if let url = history.goBack() { show(url, selecting: nil) }
    }

    @objc func goForward() {
        onActivate?()
        if let url = history.goForward() { show(url, selecting: nil) }
    }

    func goUp() {
        guard history.canGoUp else { return }
        let current = history.current
        navigate(to: ICloudDrive.parent(of: current), selecting: current)
    }

    private func show(_ url: URL, selecting selection: URL?) {
        loadViewIfNeeded()
        folder.show(url, selecting: selection, takeFocus: isActive)
        pathBar.show(url)
        backButton.isEnabled = history.canGoBack
        forwardButton.isEnabled = history.canGoForward
        onNavigate?()
    }

    private func updateHeader() {
        header.isActive = isActive
    }
}

/// The pane header's background: a light accent tint while its pane is active.
final class PaneHeaderView: NSView {
    var isActive = false {
        didSet { needsDisplay = true }
    }
    /// A click on the header itself: empty space or a separator label. Its buttons handle their own clicks.
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override var wantsUpdateLayer: Bool { true }

    // Runs in the view's appearance, so the accent color resolves for light or dark mode.
    override func updateLayer() {
        layer?.backgroundColor = isActive ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : nil
    }
}
