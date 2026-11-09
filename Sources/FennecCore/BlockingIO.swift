import Foundation

/// Runs blocking file-system work (which can hang on a permission prompt or a dead network share)
/// on a GCD queue that adds threads as needed. Swift's task pool has about one thread per core,
/// so a few stuck reads there would stall every other task in the app.
public enum BlockingIO {
    private static let queue = DispatchQueue(
        label: "dev.bvdwalt.fennec.blocking-io", qos: .userInitiated, attributes: .concurrent)

    public static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
