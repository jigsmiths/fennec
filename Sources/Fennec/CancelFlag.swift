import Foundation

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func set() { lock.withLock { cancelled = true } }
    @Sendable func get() -> Bool { lock.withLock { cancelled } }
}
