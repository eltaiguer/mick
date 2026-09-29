import AppKit

/// The four workspace signals Mick uses (SPEC.md §6.3).
public enum WorkspaceSignal: String, Sendable, CaseIterable {
    case willSleep, didWake, sessionDidResignActive, sessionDidBecomeActive

    /// The legacy notification name the system posts; the typed messages bridge from it.
    public var notificationName: Notification.Name {
        switch self {
        case .willSleep: NSWorkspace.willSleepNotification
        case .didWake: NSWorkspace.didWakeNotification
        case .sessionDidResignActive: NSWorkspace.sessionDidResignActiveNotification
        case .sessionDidBecomeActive: NSWorkspace.sessionDidBecomeActiveNotification
        }
    }
}

/// Observes the typed `NSWorkspace` main-actor messages on the workspace's own
/// notification center and forwards them to a main-actor handler.
@MainActor
public final class WorkspaceSignals {
    public typealias Handler = @MainActor (WorkspaceSignal) -> Void

    private var tokens: [NotificationCenter.ObservationToken] = []
    private let center: NotificationCenter

    /// - Parameter center: must be `NSWorkspace.shared.notificationCenter` in the app;
    ///   parameterised only so tests can show that other centers don't deliver.
    public init(center: NotificationCenter = NSWorkspace.shared.notificationCenter, handler: @escaping Handler) {
        self.center = center
        let ws = NSWorkspace.shared
        tokens = [
            center.addObserver(of: ws, for: .willSleep) { _ in
                MainActor.assertIsolated()
                handler(.willSleep)
            },
            center.addObserver(of: ws, for: .didWake) { _ in
                MainActor.assertIsolated()
                handler(.didWake)
            },
            center.addObserver(of: ws, for: .sessionDidResignActive) { _ in
                MainActor.assertIsolated()
                handler(.sessionDidResignActive)
            },
            center.addObserver(of: ws, for: .sessionDidBecomeActive) { _ in
                MainActor.assertIsolated()
                handler(.sessionDidBecomeActive)
            },
        ]
    }

    public func stop() {
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    isolated deinit {
        stop()
    }
}
