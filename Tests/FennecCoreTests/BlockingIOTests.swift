import Foundation
import Synchronization
import Testing
@testable import FennecCore

private final class Counter: Sendable {
    private let count = Atomic(0)

    func increment() { count.wrappingAdd(1, ordering: .relaxed) }
    var value: Int { count.load(ordering: .relaxed) }
}

struct BlockingIOTests {
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
