// Measures how late three ways of scheduling Mick's "check in N seconds" fire.
// Run: swift scripts/leeway.swift [seconds=30] [rounds=3]
import Foundation

let delay = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 30 : 30
let rounds = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 3 : 3

@MainActor func measure() async {
    for round in 1...rounds {
        let start = Date()
        let due = start.addingTimeInterval(delay)
        var results: [String: Double] = [:]
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var pending = 4
            func record(_ name: String) {
                results[name] = Date().timeIntervalSince(due)
                pending -= 1
                if pending == 0 { done.resume() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { record("asyncAfter") }
            }
            let t = Timer(fire: due, interval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { record("Timer(tolerance 0)") }
            }
            RunLoop.main.add(t, forMode: .common)
            let src = DispatchSource.makeTimerSource(queue: .main)
            src.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
            src.setEventHandler {
                MainActor.assumeIsolated { record("DispatchSourceTimer(leeway 100ms)") }
                src.cancel()
            }
            src.resume()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                record("Task.sleep")
            }
        }
        for (k, v) in results.sorted(by: { $0.key < $1.key }) {
            print(String(format: "round %d  %-34@ %+.3f s", round, k as NSString, v))
        }
    }
}

Task { @MainActor in
    await measure()
    exit(0)
}
RunLoop.main.run()
