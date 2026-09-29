import Foundation

/// The sitting timer (SPEC §6.3): how long you've been sitting, and the rules that
/// reset it after a break. Pure: the app feeds it idle readings and system signals.
///
/// Every reset goes through one helper that only ever moves `sitting_since` forward
/// (§7: "never backdated"), so nothing here can make displayed sitting time jump up.
public enum SittingTimer {
    /// How often the app polls system idle time (decision 16).
    public static let pollInterval: TimeInterval = 30

    /// Something the sitting timer reacts to.
    public enum Input: Equatable, Sendable {
        /// A poll of system idle time, in seconds since the last keyboard or mouse input.
        case poll(idleSeconds: Double)
        /// Mick just launched and loaded `state.json`.
        case launch
        /// The Mac woke. `sleptAt` is when `willSleep` arrived, or nil if it was missed.
        case wake(sleptAt: Date?)
        /// The login session became active again after fast user switching. `resignedAt`
        /// is when it went inactive, or nil if that was missed.
        case sessionBecameActive(resignedAt: Date?)
    }

    /// Why `sitting_since` moved.
    public enum Reset: Equatable, Sendable {
        /// Idle for at least the break-reset time at this poll.
        case idle(seconds: Double)
        /// Mick wasn't running (or you weren't touching the Mac before it quit) for this long.
        case relaunch(awaySeconds: Double)
        case sleep(seconds: Double)
        case userSwitch(seconds: Double)
    }

    /// Applies one input. Returns the reset it caused, or nil when `sitting_since`
    /// stayed where it was.
    @discardableResult
    public static func apply(_ input: Input, config: MickConfig, now: Date, to state: inout MickState) -> Reset? {
        let breakReset = TimeInterval(config.breakResetMinutes * 60)
        switch input {
        case .poll(let raw):
            let idle = sanitize(raw)
            // The last time you actually touched the Mac (decision 31), for the relaunch rule.
            state.lastActiveAt = now.addingTimeInterval(-idle)
            guard idle >= breakReset else { return nil }
            // On a break: keep sitting_since at now for as long as you're away, so
            // sitting time restarts from about the moment you come back.
            return moveSittingSince(&state, to: now) ? .idle(seconds: idle) : nil

        case .launch:
            let away = now.timeIntervalSince(state.lastActiveAt)
            guard away >= breakReset else { return nil }
            return moveSittingSince(&state, to: now) ? .relaunch(awaySeconds: away) : nil

        case .wake(let sleptAt):
            // Without a willSleep time, last_active_at is the best bound: polls don't run
            // while the Mac sleeps, so it's no later than the moment it went to sleep.
            let slept = now.timeIntervalSince(sleptAt ?? state.lastActiveAt)
            guard slept >= breakReset else { return nil }
            return moveSittingSince(&state, to: now) ? .sleep(seconds: slept) : nil

        case .sessionBecameActive(let resignedAt):
            let away = now.timeIntervalSince(resignedAt ?? state.lastActiveAt)
            guard away >= breakReset else { return nil }
            return moveSittingSince(&state, to: now) ? .userSwitch(seconds: away) : nil
        }
    }

    /// Moves `sitting_since` to `date` only if that's later. Returns true if it moved.
    static func moveSittingSince(_ state: inout MickState, to date: Date) -> Bool {
        guard date > state.sittingSince else { return false }
        state.sittingSince = date
        return true
    }

    private static func sanitize(_ idle: Double) -> Double {
        idle.isFinite && idle > 0 ? idle : 0
    }

    // MARK: - Derived values

    /// Seconds of continuous sitting. Never negative (a clock set backwards can leave
    /// `sitting_since` in the future; it's never moved back to fix that).
    public static func sittingSeconds(_ state: MickState, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(state.sittingSince))
    }

    /// When Mick is armed (§6.4 "reminder at"): the later of `sitting_since + threshold`
    /// and `nag_after`.
    public static func armedAt(_ state: MickState, config: MickConfig) -> Date {
        let byThreshold = state.sittingSince.addingTimeInterval(threshold(config))
        guard let nag = state.nagAfter else { return byThreshold }
        return max(byThreshold, nag)
    }

    /// Sitting at least the threshold, and past any `nag_after` (§6.4, §7).
    public static func isArmed(_ state: MickState, config: MickConfig, now: Date) -> Bool {
        sittingSeconds(state, now: now) >= threshold(config) && state.nagAfter.map { now >= $0 } ?? true
    }

    /// Armed and sitting at least twice the threshold (§6.4).
    public static func isGlaring(_ state: MickState, config: MickConfig, now: Date) -> Bool {
        isArmed(state, config: config, now: now) && sittingSeconds(state, now: now) >= 2 * threshold(config)
    }

    /// The dropdown's plain detail line (§6.4): "Sitting 47m · reminder at 50m", where
    /// "reminder at" is the sitting time at which Mick will be armed. Once armed it says
    /// "reminder armed" instead, since that time has passed.
    public static func detailLine(_ state: MickState, config: MickConfig, now: Date) -> String {
        let sitting = "Sitting \(format(minutes: Int(sittingSeconds(state, now: now) / 60)))"
        if isArmed(state, config: config, now: now) {
            return "\(sitting) · reminder armed"
        }
        let at = armedAt(state, config: config).timeIntervalSince(state.sittingSince)
        return "\(sitting) · reminder at \(format(minutes: Int((at / 60).rounded(.up))))"
    }

    /// `47m`, `1h`, `1h 12m`.
    public static func format(minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    private static func threshold(_ config: MickConfig) -> TimeInterval {
        TimeInterval(config.sitThresholdMinutes * 60)
    }
}
