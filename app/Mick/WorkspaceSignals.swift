import AppKit
import MickIO

/// Forwards sleep/wake and fast-user-switching messages to the engine (SPEC §6.3).
///
/// Observed on `NSWorkspace.shared.notificationCenter` (other centers never receive
/// them). The typed messages are delivered synchronously on the posting thread, which
/// is main for AppKit's own posts (signals spike, #2); never re-post them off main.
@MainActor
final class WorkspaceSignals {
    private var tokens: [NotificationCenter.ObservationToken] = []
    private let center = NSWorkspace.shared.notificationCenter

    init(engine: MickEngine) {
        let ws = NSWorkspace.shared
        tokens = [
            center.addObserver(of: ws, for: .willSleep) { [weak engine] _ in
                MainActor.assumeIsolated { engine?.willSleep() }
            },
            center.addObserver(of: ws, for: .didWake) { [weak engine] _ in
                MainActor.assumeIsolated { engine?.didWake() }
            },
            center.addObserver(of: ws, for: .sessionDidResignActive) { [weak engine] _ in
                MainActor.assumeIsolated { engine?.sessionDidResignActive() }
            },
            center.addObserver(of: ws, for: .sessionDidBecomeActive) { [weak engine] _ in
                MainActor.assumeIsolated { engine?.sessionDidBecomeActive() }
            },
        ]
    }

    var observerCount: Int { tokens.count }

    func stop() {
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    isolated deinit {
        stop()
    }
}
