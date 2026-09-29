import Foundation

/// Sitting time in Mick's words (SPEC §10.2). Lines never hardcode a duration
/// (decision 37); they use placeholders, spelled out and capitalized at the start of a
/// sentence:
/// - `{minutes}`: total minutes, as a number ("Forty-seven", "A hundred and five"). The
///   line supplies the unit ("{minutes} minutes"), which reads "minute" for exactly one.
/// - `{hours}`: rounded to the nearest half hour, unit included ("Two hours", "An hour
///   and a half"). Under a quarter of an hour, which rounds to no hours at all, it
///   falls back to minutes ("Two minutes") rather than saying "half an hour".
///
/// The plain detail line and menu labels use digits instead (`SittingTimer.format`).
public enum SpokenTime {
    public static let minutesPlaceholder = "{minutes}"
    public static let hoursPlaceholder = "{hours}"
    public static let knownPlaceholders: Set<String> = [minutesPlaceholder, hoursPlaceholder]

    /// Every `{name}` in `text`, in order.
    public static func placeholders(in text: String) -> [String] {
        var found: [String] = []
        var rest = text[...]
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            found.append(String(rest[open...close]))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    /// Fills the placeholders in `text` with a sitting time of `sittingMinutes`.
    public static func render(_ text: String, sittingMinutes: Int) -> String {
        let minutes = max(0, sittingMinutes)
        var out = ""
        var rest = text[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let name = String(rest[open...close])
            rest = rest[rest.index(after: close)...]
            var phrase: String
            switch name {
            case minutesPlaceholder:
                phrase = number(minutes)
                // "{minutes} minutes" with one minute: "One minute".
                if minutes == 1, rest.hasPrefix(" minutes"), !(rest.dropFirst(8).first?.isLetter ?? false) {
                    phrase += " minute"
                    rest = rest.dropFirst(8)
                }
            case hoursPlaceholder:
                phrase = hours(minutes)
            default:
                out += name
                continue
            }
            out += isSentenceStart(out) ? capitalizedFirst(phrase) : phrase
        }
        out += rest
        return out
    }

    /// Minutes as words, lowercase: "forty-seven", "a hundred and five".
    public static func number(_ n: Int) -> String {
        words(max(0, n), leading: true)
    }

    /// Sitting time rounded to the nearest half hour, lowercase, unit included: "half an
    /// hour", "an hour", "an hour and a half", "two hours", "two and a half hours".
    /// Under 15 minutes: "two minutes" (see the type's note).
    public static func hours(_ minutes: Int) -> String {
        let m = max(0, minutes)
        let halves = Int((Double(m) / 30).rounded(.toNearestOrAwayFromZero))
        if halves == 0 { return m == 1 ? "one minute" : "\(number(m)) minutes" }
        if halves == 1 { return "half an hour" }
        let whole = halves / 2
        let half = halves % 2 == 1
        if whole == 1 { return half ? "an hour and a half" : "an hour" }
        return half ? "\(number(whole)) and a half hours" : "\(number(whole)) hours"
    }

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// `leading`: the number starts the phrase, so a lone hundred or thousand is "a".
    private static func words(_ n: Int, leading: Bool) -> String {
        switch n {
        case ..<20:
            return ones[n]
        case ..<100:
            return tens[n / 10] + (n % 10 == 0 ? "" : "-" + ones[n % 10])
        case ..<1000:
            let head = n / 100 == 1 && leading ? "a hundred" : "\(ones[n / 100]) hundred"
            return n % 100 == 0 ? head : "\(head) and \(words(n % 100, leading: false))"
        default:
            let k = n / 1000
            let head = k == 1 && leading ? "a thousand" : "\(words(k, leading: false)) thousand"
            let rest = n % 1000
            if rest == 0 { return head }
            return rest < 100 ? "\(head) and \(words(rest, leading: false))" : "\(head) \(words(rest, leading: false))"
        }
    }

    /// True when a placeholder right after `prefix` starts a sentence: nothing before
    /// it, or the end of a sentence (`.`, `!`, `?`, `…`), ignoring spaces and quotes.
    static func isSentenceStart(_ prefix: String) -> Bool {
        let trimmed = prefix.reversed().drop(while: { $0.isWhitespace || "\"'“‘([".contains($0) })
        guard let last = trimmed.first else { return true }
        return ".!?…".contains(last)
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
