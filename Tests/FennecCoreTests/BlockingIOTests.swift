import Foundation
import Testing
@testable import FennecCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

struct BlockingIOTests {
    // Reads stuck on a permission prompt or a dead share must all be able to start, and must not
    // stop other reads from running. On a fixed-size pool only about one per core would ever start.
    @Test(.timeLimit(.minutes(1)))
    func stuckJobsDoNotStarveOtherJobs() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = Counter()
        let stuckCount = ProcessInfo.processInfo.activeProcessorCount * 3
        let stuck = (0..<stuckCount).map { _ in
            Task {
                try await BlockingIO.run {
                    started.increment()
                    gate.wait()
                }
            }
        }

        while started.value < stuckCount {
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try await BlockingIO.run { 42 }
        #expect(result == 42)

        for _ in 0..<stuckCount { gate.signal() }
        for task in stuck { try await task.value }
    }

    @Test func errorsPropagate() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await BlockingIO.run { throw Boom() } }
    }
}
