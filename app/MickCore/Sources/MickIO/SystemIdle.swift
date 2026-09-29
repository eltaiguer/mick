import CoreGraphics

/// System idle time (SPEC §6.3): seconds since the last keyboard or mouse input
/// anywhere in the login session. Public, not deprecated, and needs no Input
/// Monitoring or Accessibility permission (signals spike, #2).
public enum SystemIdle {
    /// `kCGAnyInputEventType` (`~0`) isn't bridged to Swift, so build it from its raw value.
    static let anyInputEventType = CGEventType(rawValue: ~0)

    public static func seconds() -> Double {
        guard let any = anyInputEventType else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}
