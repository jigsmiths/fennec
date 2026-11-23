import Foundation
import Synchronization

final class CancelFlag: Sendable {
    private let cancelled = Atomic(false)

    func set() { cancelled.store(true, ordering: .releasing) }
    @Sendable func get() -> Bool { cancelled.load(ordering: .acquiring) }
}
