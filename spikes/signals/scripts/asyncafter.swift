// Measures DispatchQueue.main.asyncAfter lateness on its own (no other timers to
// coalesce with) for several delays at once.
// Run: swift scripts/asyncafter.swift 30 180 600
import Foundation

let delays = CommandLine.arguments.dropFirst().compactMap(Double.init)
nonisolated(unsafe) var remaining = delays.count
for d in delays {
    let due = Date().addingTimeInterval(d)
    DispatchQueue.main.asyncAfter(deadline: .now() + d) {
        print(String(format: "asyncAfter %5.0f s: %+.3f s late", d, Date().timeIntervalSince(due)))
        remaining -= 1
        if remaining == 0 { exit(0) }
    }
}
dispatchMain()
