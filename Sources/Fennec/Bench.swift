import AppKit

/// Set FENNEC_BENCH=1 to load the start folder twice, print the warm load's timings to stderr and quit.
/// The first load is skipped because it includes one-time app launch work.
@MainActor
enum Bench {
    static let enabled = ProcessInfo.processInfo.environment["FENNEC_BENCH"] != nil
    static var recordedColdLoad = false

    static func report(entries: Int, load: Duration, paint: Duration) {
        let line = String(
            format: "%d entries: list+sort %.1fms, paint %.1fms, total %.1fms\n",
            entries, milliseconds(load), milliseconds(paint), milliseconds(load + paint))
        FileHandle.standardError.write(Data(line.utf8))
        NSApp.terminate(nil)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
