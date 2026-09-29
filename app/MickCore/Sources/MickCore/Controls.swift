import Foundation

/// The escape hatches (SPEC §6.4, §8): snooze, pause and resume. Pure; the engine
/// applies them to its state. None of them ever touches `sitting_since`.
public enum SnoozeOption: String, Equatable, Sendable, CaseIterable {
    case thirtyMinutes
    case oneHour
    case twoHours
    /// Until the next 06:00 local time. Menu only; the panel offers the first three.
    case untilTomorrow

    /// The panel's Snooze menu (§9.1).
    public static let panelOptions: [SnoozeOption] = [.thirtyMinutes, .oneHour, .twoHours]

    /// "Until tomorrow" ends at this local hour.
    public static let tomorrowHour = 6

    /// Plain menu label (§1: menu labels stay plain).
    public var label: String {
        switch self {
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .untilTomorrow: "Until tomorrow (06:00)"
        }
    }

    /// Short label for the panel's inline snooze buttons.
    public var shortLabel: String {
        switch self {
        case .thirtyMinutes: "30 min"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .untilTomorrow: "Tomorrow"
        }
    }

    /// When a snooze chosen at `now` ends. "Until tomorrow" is the next 06:00 local
    /// time strictly after `now`: at 01:00 that's 06:00 the same day, at 06:00 or later
    /// it's 06:00 the next day. DST-safe (a skipped 06:00 moves to the next valid time).
    public func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .thirtyMinutes: return now.addingTimeInterval(30 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .twoHours: return now.addingTimeInterval(2 * 60 * 60)
        case .untilTomorrow:
            let six = DateComponents(hour: Self.tomorrowHour, minute: 0, second: 0)
            return calendar.nextDate(after: now, matching: six, matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(24 * 60 * 60)
        }
    }
}

public enum Controls {
    /// Snoozes until `until`. Only `snoozed_until` changes.
    public static func snooze(_ state: inout MickState, until: Date) {
        state.snoozedUntil = until
    }

    /// Pauses. Persists in `state.json` until resumed.
    public static func pause(_ state: inout MickState) {
        state.paused = true
    }

    /// Resume: ends a pause and any snooze.
    public static func resume(_ state: inout MickState) {
        state.paused = false
        state.snoozedUntil = nil
    }

    /// Snoozed right now (a snooze that ran out reads as not snoozed).
    public static func isSnoozed(_ state: MickState, now: Date) -> Bool {
        state.snoozedUntil.map { now < $0 } ?? false
    }

    /// Paused, or inside quiet hours: both show the paused icon (§6.4).
    public static func isPausedOrQuiet(_ state: MickState, config: MickConfig, now: Date, calendar: Calendar = .current) -> Bool {
        state.paused || (config.quietHours?.contains(now, calendar: calendar) ?? false)
    }

    /// Clears a snooze that has run out. Returns true if it did.
    @discardableResult
    public static func clearExpiredSnooze(_ state: inout MickState, now: Date) -> Bool {
        guard let until = state.snoozedUntil, now >= until else { return false }
        state.snoozedUntil = nil
        return true
    }
}

/// A Mick line shown briefly in the dropdown's status line after snooze, pause or
/// resume (§6.4). In memory only.
public struct StatusNotice: Equatable, Sendable {
    public var text: String
    public var until: Date

    /// How long a notice stays in the status line.
    public static let duration: TimeInterval = 20

    public init(text: String, until: Date) {
        self.text = text
        self.until = until
    }

    public init(text: String, now: Date) {
        self.init(text: text, until: now.addingTimeInterval(Self.duration))
    }

    public func isShowing(at now: Date) -> Bool { now < until }

    /// Placeholder lines for the `snooze` / `pause` / `resume` pools until Mick's
    /// voice (#9, `lines.json`) replaces them. Durations are spelled out, never
    /// hardcoded into a pool (§10.2).
    public static func line(for action: Action) -> String {
        switch action {
        case .snooze(.thirtyMinutes): "Thirty minutes. I'll be here."
        case .snooze(.oneHour): "Sixty minutes. I'll be here."
        case .snooze(.twoHours): "Two hours. Don't make me come find ya."
        case .snooze(.untilTomorrow): "Tomorrow, then. Get some sleep, ya bum."
        case .pause: "Fine. Go soft."
        case .resume: "About time."
        }
    }

    public enum Action: Equatable, Sendable {
        case snooze(SnoozeOption)
        case pause
        case resume
    }
}
