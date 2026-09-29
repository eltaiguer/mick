import CoreGraphics

/// System idle time as specified in SPEC.md §6.3: seconds since the last input
/// event of any type, for the combined session state.
public enum IdleTime {
    /// `kCGAnyInputEventType` (`~0`) isn't bridged to Swift, so build it from its raw value.
    public static let anyInputEventType: CGEventType? = CGEventType(rawValue: ~0)

    /// Seconds since the last keyboard or mouse input anywhere in the login session.
    public static func seconds() -> Double {
        guard let any = anyInputEventType else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}
