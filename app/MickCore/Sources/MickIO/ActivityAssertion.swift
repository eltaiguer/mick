import Foundation

/// The App Nap activity (SPEC §6.3, decisions 32 and 44): held while anything is live,
/// ended otherwise, because holding one for long periods hurts energy use.
///
/// `.userInitiatedAllowingIdleSystemSleep` only; never `.latencyCritical`, which Apple
/// reserves for audio and video recording. The token is retained here: the activity
/// ends if it's deallocated.
@MainActor
public final class ActivityAssertion {
    public static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep
    public static let reason = "Mick is timing a stretch reminder"

    private let begin: @MainActor () -> any NSObjectProtocol
    private let end: @MainActor (any NSObjectProtocol) -> Void
    private var token: (any NSObjectProtocol)?

    /// Defaults to `ProcessInfo.beginActivity` / `endActivity`; tests pass fakes.
    public init(
        begin: @escaping @MainActor () -> any NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(options: ActivityAssertion.options, reason: ActivityAssertion.reason)
        },
        end: @escaping @MainActor (any NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.begin = begin
        self.end = end
    }

    public var isHeld: Bool { token != nil }

    /// Begins or ends the activity. Returns true if that changed anything.
    @discardableResult
    public func hold(_ wanted: Bool) -> Bool {
        if wanted, token == nil {
            token = begin()
            return true
        }
        if !wanted, let t = token {
            end(t)
            token = nil
            return true
        }
        return false
    }
}
