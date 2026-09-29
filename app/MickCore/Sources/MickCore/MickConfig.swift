import Foundation

/// `config.json` (SPEC §11). Missing keys take their defaults, so a hand-edited file
/// only needs the keys it changes.
public struct MickConfig: Equatable, Sendable, Codable {
    public var sitThresholdMinutes: Int
    public var breakResetMinutes: Int
    public var showDelaySeconds: Int
    public var quietHours: QuietHours?
    public var sound: Bool

    public static let defaults = MickConfig()

    public init(
        sitThresholdMinutes: Int = 50,
        breakResetMinutes: Int = 5,
        showDelaySeconds: Int = 30,
        quietHours: QuietHours? = nil,
        sound: Bool = false
    ) {
        self.sitThresholdMinutes = sitThresholdMinutes
        self.breakResetMinutes = breakResetMinutes
        self.showDelaySeconds = showDelaySeconds
        self.quietHours = quietHours
        self.sound = sound
    }

    enum CodingKeys: String, CodingKey {
        case sitThresholdMinutes = "sit_threshold_minutes"
        case breakResetMinutes = "break_reset_minutes"
        case showDelaySeconds = "show_delay_seconds"
        case quietHours = "quiet_hours"
        case sound
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MickConfig.defaults
        sitThresholdMinutes = try c.decodeIfPresent(Int.self, forKey: .sitThresholdMinutes) ?? d.sitThresholdMinutes
        breakResetMinutes = try c.decodeIfPresent(Int.self, forKey: .breakResetMinutes) ?? d.breakResetMinutes
        showDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .showDelaySeconds) ?? d.showDelaySeconds
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours)
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? d.sound
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sitThresholdMinutes, forKey: .sitThresholdMinutes)
        try c.encode(breakResetMinutes, forKey: .breakResetMinutes)
        try c.encode(showDelaySeconds, forKey: .showDelaySeconds)
        try c.encode(quietHours, forKey: .quietHours)  // explicit null, as in §11
        try c.encode(sound, forKey: .sound)
    }

    /// Replaces out-of-range values with their defaults. Returns one message per fix.
    public func validated() -> (config: MickConfig, problems: [String]) {
        var fixed = self
        var problems: [String] = []
        let d = MickConfig.defaults
        if !(1...1440).contains(sitThresholdMinutes) {
            problems.append("sit_threshold_minutes \(sitThresholdMinutes) is out of range (1-1440); using \(d.sitThresholdMinutes)")
            fixed.sitThresholdMinutes = d.sitThresholdMinutes
        }
        if !(1...1440).contains(breakResetMinutes) {
            problems.append("break_reset_minutes \(breakResetMinutes) is out of range (1-1440); using \(d.breakResetMinutes)")
            fixed.breakResetMinutes = d.breakResetMinutes
        }
        if !(0...3600).contains(showDelaySeconds) {
            problems.append("show_delay_seconds \(showDelaySeconds) is out of range (0-3600); using \(d.showDelaySeconds)")
            fixed.showDelaySeconds = d.showDelaySeconds
        }
        if let q = quietHours, !q.isValid {
            problems.append("quiet_hours \(q.start)-\(q.end) isn't HH:MM-HH:MM; quiet hours off")
            fixed.quietHours = nil
        }
        return (fixed, problems)
    }
}

/// `{ "start": "HH:MM", "end": "HH:MM" }` in local time; may cross midnight.
public struct QuietHours: Equatable, Sendable, Codable {
    public var start: String
    public var end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }

    /// Minutes after local midnight, or nil if not `HH:MM`.
    public static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    public var isValid: Bool { Self.minutes(start) != nil && Self.minutes(end) != nil }
}
