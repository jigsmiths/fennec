import Foundation

public struct NavigationHistory: Sendable {
    public private(set) var current: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    public init(start: URL) {
        current = start
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }
    public var canGoUp: Bool { current.standardizedFileURL.path != "/" }

    public mutating func visit(_ url: URL) {
        guard url.standardizedFileURL.path != current.standardizedFileURL.path else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = url
    }

    public mutating func goBack() -> URL? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = previous
        return current
    }

    public mutating func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return current
    }
}
