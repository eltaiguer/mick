import Foundation

/// Decisions about reading and rotating `events.jsonl` (SPEC §6.3), kept pure so they
/// can be tested without a file system.
public enum EventFilePolicy {
    public static let fileName = "events.jsonl"
    public static let rotatedFileName = "events.jsonl.old"
    /// Rotate once the file passes this size and everything has been read.
    public static let rotateBytes: UInt64 = 256 * 1024
    /// How long after a rotation the app drains `events.jsonl.old` and deletes it.
    public static let drainDelay: TimeInterval = 2

    /// The offset to read from: the saved one, unless the file is now shorter
    /// (truncated or replaced externally), in which case 0.
    public static func startOffset(saved: UInt64, fileSize: UInt64) -> UInt64 {
        saved > fileSize ? 0 : saved
    }

    /// True when the file passed the rotation size and has been read to the end.
    public static func shouldRotate(fileSize: UInt64, offset: UInt64, limit: UInt64 = rotateBytes) -> Bool {
        fileSize > limit && offset >= fileSize
    }
}

/// Whether the Claude Code hooks look installed (SPEC §6.4, §6.6).
public enum HooksStatus: Equatable, Sendable {
    /// No event has ever arrived.
    case notDetected
    case detected(lastEventAt: Date)
    /// The last event is 7 days old or older: the plugin may be broken or removed.
    case stale(lastEventAt: Date)

    public static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    public static func evaluate(lastEventAt: Date?, now: Date) -> HooksStatus {
        guard let last = lastEventAt else { return .notDetected }
        return now.timeIntervalSince(last) >= staleAfter ? .stale(lastEventAt: last) : .detected(lastEventAt: last)
    }

    /// Onboarding's check mark: an event has arrived at some point.
    public var everDetected: Bool {
        if case .notDetected = self { return false }
        return true
    }

    public var showsWarning: Bool {
        if case .detected = self { return false }
        return true
    }

    /// The plain line at the top of the dropdown in the warning state, or nil.
    public var menuLine: String? {
        switch self {
        case .notDetected: "Claude Code hooks not detected. Set up…"
        case .stale: "No Claude Code events in 7 days. Set up…"
        case .detected: nil
        }
    }
}

/// Menu bar icon states (SPEC §6.4). Snoozed and paused arrive with #10.
public enum MenuBarIcon: String, Equatable, Sendable, CaseIterable {
    case calm, armed, glaring, snoozed, paused, warning

    /// Calm or warning, from the hooks alone.
    public static func current(hooks: HooksStatus) -> MenuBarIcon {
        hooks.showsWarning ? .warning : .calm
    }

    /// The icon for the whole state. A setup problem outranks everything else, since
    /// no reminder can fire without the hooks; then glaring, armed, calm.
    public static func current(hooks: HooksStatus, state: MickState, config: MickConfig, now: Date) -> MenuBarIcon {
        if hooks.showsWarning { return .warning }
        if SittingTimer.isGlaring(state, config: config, now: now) { return .glaring }
        if SittingTimer.isArmed(state, config: config, now: now) { return .armed }
        return .calm
    }
}
