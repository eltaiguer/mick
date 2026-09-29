import Foundation

/// Reading `config.json` the forgiving way (SPEC §11): the file is meant to be edited
/// by hand, so one bad value only costs that value. Each key is read on its own; a key
/// with the wrong type or an out-of-range value takes its default, and every such fix
/// is reported so it can be logged. Unknown keys are ignored.
public enum ConfigFile {
    public enum Parsed: Equatable, Sendable {
        /// A JSON object: the config it describes, plus one message per value that
        /// fell back to its default.
        case config(MickConfig, problems: [String])
        /// Not a JSON object at all (a typo, a half-written file).
        case unreadable(String)
    }

    public static func parse(_ data: Data) -> Parsed {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .unreadable("not valid JSON")
        }
        guard let dict = object as? [String: Any] else { return .unreadable("not a JSON object") }

        let d = MickConfig.defaults
        var config = MickConfig.defaults
        var problems: [String] = []

        func int(_ key: String, _ fallback: Int) -> Int {
            guard let raw = dict[key] else { return fallback }
            if let value = integer(raw) { return value }
            problems.append("\(key) \(describe(raw)) isn't a whole number; using \(fallback)")
            return fallback
        }
        config.sitThresholdMinutes = int("sit_threshold_minutes", d.sitThresholdMinutes)
        config.breakResetMinutes = int("break_reset_minutes", d.breakResetMinutes)
        config.showDelaySeconds = int("show_delay_seconds", d.showDelaySeconds)

        if let raw = dict["sound"] {
            if let flag = boolean(raw) {
                config.sound = flag
            } else {
                problems.append("sound \(describe(raw)) isn't true or false; using \(d.sound)")
            }
        }

        if let raw = dict["quiet_hours"], !(raw is NSNull) {
            if let q = raw as? [String: Any], let start = q["start"] as? String, let end = q["end"] as? String {
                config.quietHours = QuietHours(start: start, end: end)
            } else {
                problems.append("quiet_hours isn't null or {\"start\": \"HH:MM\", \"end\": \"HH:MM\"}; quiet hours off")
            }
        }

        let (valid, rangeProblems) = config.validated()
        return .config(valid, problems: problems + rangeProblems)
    }

    /// JSON numbers that are whole (50, 50.0), not booleans.
    private static func integer(_ raw: Any) -> Int? {
        guard let n = raw as? NSNumber, !isBoolean(n) else { return nil }
        let value = n.doubleValue
        guard value.isFinite, value.rounded() == value, abs(value) < 1e9 else { return nil }
        return Int(value)
    }

    private static func boolean(_ raw: Any) -> Bool? {
        guard let n = raw as? NSNumber, isBoolean(n) else { return nil }
        return n.boolValue
    }

    private static func isBoolean(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func describe(_ raw: Any) -> String {
        switch raw {
        case let s as String: "\"\(s.prefix(40))\""
        case is NSNull: "null"
        case let n as NSNumber: isBoolean(n) ? (n.boolValue ? "true" : "false") : n.stringValue
        case is [Any]: "(a list)"
        case is [String: Any]: "(an object)"
        default: "(unknown)"
        }
    }
}

extension MickConfig {
    /// The ranges `validated()` enforces, for the Settings window's steppers.
    public static let sitThresholdRange = 1...1440
    public static let breakResetRange = 1...1440
    public static let showDelayRange = 0...3600
}

extension QuietHours {
    /// `HH:MM` for minutes after midnight (wrapped into one day).
    public static func string(minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// What the Settings window offers when quiet hours are first turned on.
    public static let suggested = QuietHours(start: "22:00", end: "07:00")
}
