import Foundation

/// ISO 8601 timestamps for Mick's files (SPEC §12.1), in UTC with microseconds.
///
/// Microseconds matter: event ordering (§6.3) compares an incoming event's `t` against
/// the session's last applied time, which survives relaunch through `state.json`. The
/// hook's `t` comes from jq's `now` (microsecond resolution), so millisecond ISO strings
/// would let a late event from the same millisecond slip through after a relaunch.
public enum MickDate {
    /// `2026-09-29T13:05:01.123456Z`
    public static func string(from date: Date) -> String {
        let micros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        var whole = (micros / 1_000_000).rounded(.down)
        var fraction = Int(micros - whole * 1_000_000)
        if fraction >= 1_000_000 { whole += 1; fraction -= 1_000_000 }
        let base = Date(timeIntervalSince1970: whole).formatted(
            Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().dateSeparator(.dash)
                .time(includingFractionalSeconds: false).timeSeparator(.colon)
        )
        return "\(base).\(String(format: "%06d", fraction))Z"
    }

    /// Accepts any number of fraction digits (or none) and a `Z` or `±HH:MM` offset.
    public static func date(from string: String) -> Date? {
        var text = Substring(string)
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let digitsEnd = text[text.index(after: dot)...].firstIndex { !$0.isNumber } ?? text.endIndex
            let digits = text[text.index(after: dot)..<digitsEnd]
            guard !digits.isEmpty, let value = Double("0." + digits) else { return nil }
            fraction = value
            text = text[..<dot] + text[digitsEnd...]
        }
        guard let base = try? Date.ISO8601FormatStyle().parse(String(text)) else { return nil }
        return base.addingTimeInterval(fraction)
    }

    /// Two times compared at the microsecond resolution they're stored with.
    public static func micros(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    /// Local calendar date as `YYYY-MM-DD` (for `today.date`, §12.1).
    public static func localDay(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

extension JSONEncoder {
    /// Encoder for Mick's JSON files: sorted keys, pretty printed, MickDate timestamps.
    public static func mick() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(MickDate.string(from: date))
        }
        return encoder
    }
}

extension JSONDecoder {
    public static func mick() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = MickDate.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }
}
