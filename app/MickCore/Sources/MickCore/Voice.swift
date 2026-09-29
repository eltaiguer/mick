import Foundation

/// Mick's voice on the reminder panel (SPEC §10.2): which pools a reminder draws from,
/// and the lines rendered for its sitting time. Pure; the engine commits the rotation.
public enum Voice {
    /// The lines picked for one reminder. The opener is committed to the rotation when
    /// the panel shows; each done line only when it actually shows, so a reminder that's
    /// ignored doesn't use one up.
    public struct ReminderLines: Equatable, Sendable {
        public var openerPool: LinePool
        public var opener: Line
        public var doneAll: Line
        public var donePartial: Line
        /// The rotation with the opener marked used.
        public var rotation: MickState.Rotation

        public init(openerPool: LinePool, opener: Line, doneAll: Line, donePartial: Line, rotation: MickState.Rotation) {
            self.openerPool = openerPool
            self.opener = opener
            self.doneAll = doneAll
            self.donePartial = donePartial
            self.rotation = rotation
        }
    }

    /// Picks the opener (by precedence: ignored tier, then long sit, then normal) and
    /// the two done lines for a reminder.
    public static func pickReminderLines(
        kind: Routine.Kind, ignoredToday: Int, catalog: LineCatalog, rotation: MickState.Rotation,
        using rng: inout some RandomNumberGenerator
    ) -> ReminderLines? {
        let pool = LinePool.opener(ignoredToday: ignoredToday, kind: kind)
        guard let opener = Lines.pick(pool, catalog: catalog, rotation: rotation, using: &rng),
              let all = Lines.pick(.doneAll, catalog: catalog, rotation: rotation, using: &rng),
              let partial = Lines.pick(.donePartial, catalog: catalog, rotation: rotation, using: &rng)
        else { return nil }
        return ReminderLines(openerPool: pool, opener: opener.line, doneAll: all.line, donePartial: partial.line,
                             rotation: opener.rotation)
    }

    /// Fills `content`'s lines for a reminder shown after `sittingMinutes` of sitting.
    /// A long sit with an ignored-tier opener gets the plain detail line (decision 28).
    public static func apply(_ lines: ReminderLines, kind: Routine.Kind, sittingMinutes: Int, to content: inout ReminderContent) {
        content.opener = SpokenTime.render(lines.opener.text, sittingMinutes: sittingMinutes)
        content.doneLine = SpokenTime.render(lines.doneAll.text, sittingMinutes: sittingMinutes)
        content.partialLine = SpokenTime.render(lines.donePartial.text, sittingMinutes: sittingMinutes)
        let tiered = lines.openerPool != .opener && lines.openerPool != .openerLongSit
        content.detail = kind == .longSit && tiered ? detailLine(sittingMinutes: sittingMinutes) : nil
    }

    /// The panel's plain detail line, in digits like the menu: "Sitting 1h 47m".
    public static func detailLine(sittingMinutes: Int) -> String {
        "Sitting \(SittingTimer.format(minutes: sittingMinutes))"
    }
}

/// The rules every line Mick says must follow (SPEC §1, Mick's voice; decisions 12 and
/// 37), as checks a test runs over the whole of `lines.json`. They catch the mechanical
/// part; originality and tone still need a human read.
public enum VoiceRules {
    /// Stronger than "bum", "crap" and "damn" (mild language only).
    static let strongLanguage = [
        "shit", "fuck", "ass", "arse", "bitch", "bastard", "hell", "piss", "dick", "cock",
        "goddamn", "goddam", "christ", "jesus", "screw you", "sucks", "wtf",
    ]
    /// Mick insults sitting and laziness only: never body, appearance, weight, health,
    /// age, identity or smarts.
    static let offLimits = [
        "fat", "weight", "pounds", "belly", "gut", "flab", "chubby", "pudgy", "lard", "skinny",
        "ugly", "bald", "wrinkl", "old man", "grandpa", "grandma", "geezer", "stupid", "idiot",
        "dumb", "moron", "sick", "disease", "weakling", "girl", "sissy", "wimp", "freak", "loser",
    ]
    /// Never "push through pain": no pain, burn or toughing it out.
    static let pushingThroughPain = [
        "pain", "hurt", "push through", "burn", "ache", "suffer", "tough it out", "walk it off",
        "no excuses", "bleed",
    ]
    /// Well-known lines and names from the films. Original writing only.
    static let filmQuotes = [
        "rocky", "balboa", "adrian", "apollo", "creed", "mickey", "goldmill", "stallion",
        "eye of the tiger", "gonna fly now", "eat lightning", "eat lightnin", "crap thunder",
        "women weaken legs", "hear no bell", "heard no bell", "hear any bell", "cuz mickey loves you",
        "'cause mickey loves you", "son of a", "tomato", "yo,", "absolutely", "how hard you can get hit",
        "how hard you hit", "going the distance", "go the distance", "keep moving forward",
    ]
    /// Units that would be a hardcoded duration unless a placeholder supplies the number.
    static let timeUnits = ["second", "sec", "minute", "min", "hour", "hr", "half an", "an hour"]

    /// What's wrong with `text`, empty when it follows the rules.
    public static func problems(in text: String) -> [String] {
        var found: [String] = []
        let lower = text.lowercased()
        let words = wordList(lower)
        func has(_ term: String) -> Bool {
            term.contains(where: { !$0.isLetter }) ? lower.contains(term) : words.contains { $0 == term || $0.hasPrefix(term) && term.count >= 4 }
        }
        for term in strongLanguage where has(term) { found.append("strong language: \(term)") }
        for term in offLimits where has(term) { found.append("off-limits insult: \(term)") }
        for term in pushingThroughPain where has(term) { found.append("pushes through pain: \(term)") }
        for term in filmQuotes where has(term) { found.append("film quote or name: \(term)") }
        if text.contains(where: \.isNumber) { found.append("hardcoded number") }
        // A time unit is fine only right after {minutes} ("{minutes} minutes").
        let withoutPlaceholderUnits = lower.replacingOccurrences(of: "{minutes} minutes", with: "{minutes}")
        let unitWords = wordList(withoutPlaceholderUnits.replacingOccurrences(of: "{minutes}", with: " ").replacingOccurrences(of: "{hours}", with: " "))
        let joined = " " + unitWords.joined(separator: " ") + " "
        for unit in timeUnits {
            let hit = unit.contains(" ") ? joined.contains(" \(unit) ") : unitWords.contains { $0 == unit || $0 == unit + "s" }
            if hit { found.append("hardcoded duration: \(unit)") }
        }
        for p in SpokenTime.placeholders(in: text) where !SpokenTime.knownPlaceholders.contains(p) {
            found.append("unknown placeholder \(p)")
        }
        return found
    }

    /// Lowercase words, apostrophes kept inside ("ain't", "doin'").
    public static func wordList(_ lower: String) -> [String] {
        lower.split(whereSeparator: { !($0.isLetter || $0 == "'") })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }
}
