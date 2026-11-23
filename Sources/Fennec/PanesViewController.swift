import AppKit
import FennecCore

@MainActor
final class PanesViewController: NSSplitViewController {
    var onActivePaneChange: (() -> Void)?
    var onStateChange: (() -> Void)?
    var configurePane: ((PaneController) -> Void)?

    private(set) var panes: [PaneController] = []
    private(set) var activeIndex = 0
    private var otherFolder: URL?
    private var splitRatio: Double
    private var showHidden: Bool
    private var applyingRatio = false
    private var isSetUp = false

    private static let minimumPaneWidth: CGFloat = 280

    init(state: WindowState) {
        splitRatio = state.splitRatio
        showHidden = state.showHidden
        otherFolder = state.otherFolder.map { URL(filePath: $0, directoryHint: .isDirectory) }
        activeIndex = state.activePane
        super.init(nibName: nil, bundle: nil)
        let divider = PanesSplitView()
        divider.onDoubleClickDivider = { [weak self] in self?.evenOut() }
        splitView = divider
        panes = state.panes.map { PaneController(state: $0, showHidden: state.showHidden) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var active: PaneController { panes[activeIndex] }
    var other: PaneController? { panes.count == 2 ? panes[1 - activeIndex] : nil }
    var isSplit: Bool { panes.count == 2 }

    func start() {
        guard !isSetUp else { return }
        isSetUp = true
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        for pane in panes { addItem(for: pane) }
        for (index, pane) in panes.enumerated() { pane.isActive = index == activeIndex }
        for pane in panes { pane.showCurrent() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if splitView.frame != view.bounds { splitView.frame = view.bounds }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyRatio()
        active.folder.focus()
    }

    func state(frame: CGRect?, previewVisible: Bool) -> WindowState {
        WindowState(
            frame: frame, panes: panes.map(\.state), activePane: activeIndex,
            otherFolder: isSplit ? nil : otherFolder?.path, splitRatio: splitRatio,
            previewVisible: previewVisible, showHidden: showHidden)
    }

    func setShowHidden(_ show: Bool) {
        showHidden = show
        for pane in panes { pane.folder.showHidden = show }
        onStateChange?()
    }

    var showsHidden: Bool { showHidden }

    func activate(_ pane: PaneController) {
        guard let index = panes.firstIndex(where: { $0 === pane }), index != activeIndex else { return }
        activeIndex = index
        for (i, pane) in panes.enumerated() { pane.isActive = i == index }
        onActivePaneChange?()
        onStateChange?()
    }

    func switchPane() {
        guard let other else { return }
        activate(other)
        other.folder.focus()
    }

    func toggleSplit() {
        if isSplit { closeSplit() } else { openSplit() }
    }

    func openSplit(at folder: URL? = nil) {
        guard !isSplit else { return }
        let start = folder ?? WindowState.secondPaneFolder(remembered: otherFolder, active: active.currentFolder)
        let pane = PaneController(
            state: PaneState(folder: start.path, viewMode: active.folder.viewMode, sortOrder: active.folder.sortOrder),
            showHidden: showHidden)
        panes.append(pane)
        addItem(for: pane)
        pane.isActive = false
        pane.showCurrent()
        splitView.layoutSubtreeIfNeeded()
        applyRatio()
        onStateChange?()
    }

    func closeSplit() {
        guard let other else { return }
        otherFolder = other.currentFolder
        if let item = splitViewItems.first(where: { $0.viewController === other }) {
            removeSplitViewItem(item)
        }
        panes.removeAll { $0 === other }
        activeIndex = 0
        active.isActive = true
        active.folder.focus()
        onStateChange?()
    }

    private func addItem(for pane: PaneController) {
        configurePane?(pane)
        pane.onActivate = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.activate(pane)
            pane.folder.focus()
        }
        pane.folder.onFocus = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.activate(pane)
        }
        pane.folder.onSwitchPane = { [weak self] in self?.switchPane() }
        pane.folder.onSettingsChange = { [weak self] in self?.onStateChange?() }
        let item = NSSplitViewItem(viewController: pane)
        item.minimumThickness = Self.minimumPaneWidth
        item.holdingPriority = .defaultLow
        addSplitViewItem(item)
    }

    private func applyRatio() {
        guard isSplit else { return }
        let width = splitView.bounds.width - splitView.dividerThickness
        guard width > 0 else { return }
        applyingRatio = true
        splitView.setPosition((width * splitRatio).rounded(), ofDividerAt: 0)
        applyingRatio = false
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard isSplit, !applyingRatio, let first = splitView.arrangedSubviews.first else { return }
        guard (splitView as? PanesSplitView)?.isDraggingDivider == true else {
            applyRatio()
            return
        }
        let width = splitView.bounds.width - splitView.dividerThickness
        guard width > 0 else { return }
        let ratio = min(max(first.frame.width / width, WindowState.ratioRange.lowerBound), WindowState.ratioRange.upperBound)
        if abs(ratio - splitRatio) > 0.001 {
            splitRatio = ratio
            onStateChange?()
        }
    }

    private func evenOut() {
        splitRatio = 0.5
        applyRatio()
        onStateChange?()
    }
}

final class PanesSplitView: NSSplitView {
    var onDoubleClickDivider: (() -> Void)?
    /// True while the user drags the divider; super.mouseDown runs the whole drag.
    private(set) var isDraggingDivider = false

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClickDivider {
            onDoubleClickDivider()
            return
        }
        isDraggingDivider = true
        defer { isDraggingDivider = false }
        super.mouseDown(with: event)
    }
}
