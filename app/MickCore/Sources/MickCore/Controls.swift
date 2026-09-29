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
