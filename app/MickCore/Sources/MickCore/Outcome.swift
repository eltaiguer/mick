import Foundation

/// How a settled reminder went (SPEC §8), and what Mick remembers because of it.
public enum Outcome: String, Equatable, Sendable, Codable, CaseIterable {
    case completed
    case partial
    case stoodUp = "stood_up"
    case ignored
    case snoozed

    /// Nothing ticked, but an idle stretch at least this long counts as Stood up (§8,
    /// decision 8). Deliberately generous.
    public static let stoodUpIdleSeconds: TimeInterval = 60

    /// The §8 table, top to bottom, first match wins (Snoozed first when it applies).
    /// "Not now" and closing with nothing ticked are judged like any other close.
    public static func judge(_ s: Reminder.Settling) -> Outcome {
        if s.reason == .snoozed { return .snoozed }
        let p = s.panel
        if !p.content.items.isEmpty, p.ticked.count == p.content.items.count { return .completed }
        if !p.ticked.isEmpty { return .partial }
        if p.maxIdleSeconds >= stoodUpIdleSeconds { return .stoodUp }
        return .ignored
    }

    /// Applies this outcome's effect to `state` (§8), for a reminder settled at
    /// `settledAt`:
    /// - Completed, Partial, Stood up: `sitting_since` moves to the settle time (never
    ///   backwards) and `nag_after` clears.
    /// - Ignored: `sitting_since` unchanged, `nag_after = settled_at + threshold/2`,
    ///   `ignored_today += 1`. For a manual reminder (Stretch now) it does nothing
    ///   (decision 38).
    /// - Snoozed: `sitting_since` unchanged, no counter change; `nag_after` clears.
    public func apply(settledAt: Date, manual: Bool, config: MickConfig, now: Date,
                      calendar: Calendar = .current, to state: inout MickState) {
        switch self {
        case .completed, .partial, .stoodUp:
            _ = SittingTimer.moveSittingSince(&state, to: settledAt)
            state.nagAfter = nil
        case .snoozed:
            state.nagAfter = nil
        case .ignored:
            guard !manual else { return }
            let half = TimeInterval(config.sitThresholdMinutes * 60) / 2
            state.nagAfter = settledAt.addingTimeInterval(half)
            MickMemory.rollOver(&state, now: now, calendar: calendar)
            state.today.ignored += 1
        }
    }
}

/// Mick's memory of today (§8, decision 2): how many reminders you ignored since local
/// midnight. It only picks which lines Mick uses and is never shown as a number.
public enum MickMemory {
    /// Starts a new day when the local date moved on (or changed at all, such as a
    /// clock or time zone change): `ignored` goes back to 0. Returns true if it did.
    @discardableResult
    public static func rollOver(_ state: inout MickState, now: Date, calendar: Calendar = .current) -> Bool {
        let day = MickDate.localDay(now, calendar: calendar)
        guard state.today.date != day else { return false }
        state.today = MickState.Today(date: day, ignored: 0)
        return true
    }

    /// Reminders ignored today, as of `now`: a count left over from an earlier day
    /// reads as 0 even before `rollOver` runs.
    public static func ignoredToday(_ state: MickState, now: Date, calendar: Calendar = .current) -> Int {
        state.today.date == MickDate.localDay(now, calendar: calendar) ? state.today.ignored : 0
    }
}

/// One line of `reminders.jsonl` (SPEC §12.3), for the two-week review. Never shown in
/// the UI, and never contains prompt text or agent output.
public struct ReminderRecord: Equatable, Sendable, Codable {
    public var shownAt: Date
    public var settledAt: Date
    public var sessionID: String?
    public var cwd: String?
    public var sittingMinutes: Int
    /// Item ids, in order.
    public var routine: [String]
    public var ticked: [String]
    public var maxIdleSeconds: Int
    public var outcome: Outcome
    public var manual: Bool

    public init(shownAt: Date, settledAt: Date, sessionID: String?, cwd: String?, sittingMinutes: Int,
                routine: [String], ticked: [String], maxIdleSeconds: Int, outcome: Outcome, manual: Bool) {
        self.shownAt = shownAt
        self.settledAt = settledAt
        self.sessionID = sessionID
        self.cwd = cwd
        self.sittingMinutes = sittingMinutes
        self.routine = routine
        self.ticked = ticked
        self.maxIdleSeconds = maxIdleSeconds
        self.outcome = outcome
        self.manual = manual
    }

    /// The record for a settled reminder. `sitting_minutes` is the sitting time when
    /// the panel appeared (what the reminder was about).
    public init(_ s: Reminder.Settling, outcome: Outcome) {
        self.init(
            shownAt: s.panel.shownAt, settledAt: s.until, sessionID: s.panel.sessionID, cwd: s.panel.cwd,
            sittingMinutes: s.panel.sittingMinutes, routine: s.panel.content.items.map(\.id),
            ticked: s.panel.tickedItemIDs, maxIdleSeconds: Int(s.panel.maxIdleSeconds.rounded(.down)),
            outcome: outcome, manual: s.panel.isManual
        )
    }

    enum CodingKeys: String, CodingKey {
        case shownAt = "shown_at"
        case settledAt = "settled_at"
        case sessionID = "session_id"
        case cwd
        case sittingMinutes = "sitting_minutes"
        case routine
        case ticked
        case maxIdleSeconds = "max_idle_seconds"
        case outcome
        case manual
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shownAt, forKey: .shownAt)
        try c.encode(settledAt, forKey: .settledAt)
        try c.encode(sessionID, forKey: .sessionID)  // null for a manual reminder
        try c.encode(cwd, forKey: .cwd)
        try c.encode(sittingMinutes, forKey: .sittingMinutes)
        try c.encode(routine, forKey: .routine)
        try c.encode(ticked, forKey: .ticked)
        try c.encode(maxIdleSeconds, forKey: .maxIdleSeconds)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(manual, forKey: .manual)
    }

    /// One compact JSON line (no trailing newline), keys sorted.
    public func jsonLine() throws -> String {
        let encoder = JSONEncoder.mick()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// A settled reminder, judged: what the engine applies and logs.
public struct Settlement: Equatable, Sendable {
    public var settling: Reminder.Settling
    public var outcome: Outcome

    public init(_ settling: Reminder.Settling) {
        self.settling = settling
        self.outcome = Outcome.judge(settling)
    }

    public var record: ReminderRecord { ReminderRecord(settling, outcome: outcome) }

    /// Rolls today over if needed and applies the outcome at the settle time.
    public func apply(config: MickConfig, now: Date, calendar: Calendar = .current, to state: inout MickState) {
        MickMemory.rollOver(&state, now: now, calendar: calendar)
        outcome.apply(settledAt: settling.until, manual: settling.panel.isManual, config: config,
                      now: now, calendar: calendar, to: &state)
    }
}
