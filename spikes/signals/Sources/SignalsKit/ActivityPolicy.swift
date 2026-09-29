import Foundation

/// The App Nap activity assertion from SPEC.md §6.3 / decision 44.
public enum ActivityPolicy {
    /// User-initiated, idle system sleep allowed. Never `.latencyCritical`.
    public static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep

    public static let reason = "Mick is tracking a running agent session"
}

/// Holds the activity token for as long as the holder is alive. The activity
/// ends if the token is deallocated, so the token is retained explicitly.
@MainActor
public final class ActivityHolder {
    private var token: (any NSObjectProtocol)?

    public init() {}

    public var isHeld: Bool { token != nil }

    public func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(options: ActivityPolicy.options, reason: ActivityPolicy.reason)
    }

    public func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}
