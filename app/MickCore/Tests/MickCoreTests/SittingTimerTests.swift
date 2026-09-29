import Foundation
import Testing
@testable import MickCore

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let config = MickConfig.defaults  // 50 min threshold, 5 min break reset
private let minute: TimeInterval = 60

private func state(sittingSince: Date = t0, lastActiveAt: Date? = nil, nagAfter: Date? = nil) -> MickState {
    var s = MickState.defaults(now: t0)
    s.sittingSince = sittingSince
    s.lastActiveAt = lastActiveAt ?? sittingSince
    s.nagAfter = nagAfter
    return s
}

/// Simulates the app's 30 s polls from `start` for `duration`, with the Mac in use
/// (idle ~0) except during `away`, where idle grows from the start of the break.
private func simulate(_ s: inout MickState, from start: Date, for duration: TimeInterval,
                      away: ClosedRange<TimeInterval>? = nil, config: MickConfig = config) {
    var offset: TimeInterval = 0
    while offset <= duration {
        let now = start.addingTimeInterval(offset)
        let idle: Double = away.map { $0.contains(offset) ? offset - $0.lowerBound : 1 } ?? 1
        SittingTimer.apply(.poll(idleSeconds: idle), config: config, now: now, to: &s)
        offset += SittingTimer.pollInterval
    }
}

@Suite struct SittingTimerIdleTests {
    @Test func pollsEvery30Seconds() {
        #expect(SittingTimer.pollInterval == 30)
    }

    @Test func pollRecordsLastActiveAsNowMinusIdle() {
        var s = state()
        let now = t0.addingTimeInterval(10 * minute)
        SittingTimer.apply(.poll(idleSeconds: 42), config: config, now: now, to: &s)
        #expect(s.lastActiveAt == now.addingTimeInterval(-42))
        #expect(s.sittingSince == t0)
    }

    @Test func idleBelowTheBreakResetDoesNothing() {
        var s = state()
        let reset = SittingTimer.apply(.poll(idleSeconds: 5 * minute - 1), config: config, now: t0.addingTimeInterval(30 * minute), to: &s)
        #expect(reset == nil)
        #expect(s.sittingSince == t0)
    }

    @Test func idleAtTheBreakResetMovesSittingSinceToNow() {
        var s = state()
        let now = t0.addingTimeInterval(30 * minute)
        let reset = SittingTimer.apply(.poll(idleSeconds: 5 * minute), config: config, now: now, to: &s)
        #expect(reset == .idle(seconds: 5 * minute))
        #expect(s.sittingSince == now)
    }

    @Test func aFortyMinuteBreakLeavesSittingTimeNearZero() {
        // 30 min of work, a 40 min break, then back at the keyboard for 1 minute.
        var s = state()
        simulate(&s, from: t0, for: 71 * minute, away: (30 * minute)...(70 * minute))
        let now = t0.addingTimeInterval(71 * minute)
        let sitting = SittingTimer.sittingSeconds(s, now: now)
        // Not 35 minutes (the break minus the reset time): about the minute since coming back.
        #expect(sitting <= 90)
        #expect(SittingTimer.detailLine(s, config: config, now: now).hasPrefix("Sitting 1m"))
    }

    @Test func sittingSinceKeepsMovingForwardThroughoutTheBreak() {
        var s = state()
        var previous = s.sittingSince
        var moves = 0
        for offset in stride(from: 0.0, through: 40 * minute, by: 30) {
            let now = t0.addingTimeInterval(20 * minute + offset)
            SittingTimer.apply(.poll(idleSeconds: offset), config: config, now: now, to: &s)
            if s.sittingSince != previous { moves += 1; previous = s.sittingSince }
            if offset >= 5 * minute { #expect(s.sittingSince == now) }
        }
        #expect(moves == 71)  // every poll from 5:00 to 40:00 idle
    }

    @Test func respectsAConfiguredBreakReset() {
        var custom = MickConfig.defaults
        custom.breakResetMinutes = 10
        var s = state()
        #expect(SittingTimer.apply(.poll(idleSeconds: 9 * minute), config: custom, now: t0.addingTimeInterval(minute * 60), to: &s) == nil)
        #expect(SittingTimer.apply(.poll(idleSeconds: 10 * minute), config: custom, now: t0.addingTimeInterval(minute * 60), to: &s) != nil)
    }

    @Test func badIdleReadingsCountAsActive() {
        for bad in [Double.nan, .infinity, -5] {
            var s = state()
            let now = t0.addingTimeInterval(60 * minute)
            #expect(SittingTimer.apply(.poll(idleSeconds: bad), config: config, now: now, to: &s) == nil)
            #expect(s.lastActiveAt == now)
            #expect(s.sittingSince == t0)
        }
    }
}

@Suite struct SittingTimerSignalTests {
    @Test func sleepingForTheBreakResetResetsToTheWakeTime() {
        var s = state()
        let sleptAt = t0.addingTimeInterval(40 * minute)
        let wake = sleptAt.addingTimeInterval(5 * minute)
        #expect(SittingTimer.apply(.wake(sleptAt: sleptAt), config: config, now: wake, to: &s) == .sleep(seconds: 5 * minute))
        #expect(s.sittingSince == wake)
    }

    @Test func aShortSleepDoesNothing() {
        var s = state()
        let sleptAt = t0.addingTimeInterval(40 * minute)
        #expect(SittingTimer.apply(.wake(sleptAt: sleptAt), config: config, now: sleptAt.addingTimeInterval(4 * minute), to: &s) == nil)
        #expect(s.sittingSince == t0)
    }

    @Test func aMissedWillSleepFallsBackToLastActive() {
        var s = state(lastActiveAt: t0.addingTimeInterval(40 * minute))
        let wake = t0.addingTimeInterval(60 * minute)
        #expect(SittingTimer.apply(.wake(sleptAt: nil), config: config, now: wake, to: &s) == .sleep(seconds: 20 * minute))
        #expect(s.sittingSince == wake)

        var short = state(lastActiveAt: t0.addingTimeInterval(58 * minute))
        #expect(SittingTimer.apply(.wake(sleptAt: nil), config: config, now: wake, to: &short) == nil)
    }

    @Test func quittingForTheBreakResetResetsOnRelaunch() {
        // Last touched the Mac at 40 min (recorded as now - idle), relaunched at 46 min.
        var s = state(lastActiveAt: t0.addingTimeInterval(40 * minute))
        let launch = t0.addingTimeInterval(46 * minute)
        #expect(SittingTimer.apply(.launch, config: config, now: launch, to: &s) == .relaunch(awaySeconds: 6 * minute))
        #expect(s.sittingSince == launch)
    }

    @Test func aQuickRelaunchKeepsSittingTime() {
        var s = state(lastActiveAt: t0.addingTimeInterval(40 * minute))
        #expect(SittingTimer.apply(.launch, config: config, now: t0.addingTimeInterval(44 * minute), to: &s) == nil)
        #expect(s.sittingSince == t0)
    }

    @Test func relaunchCountsIdleBeforeTheQuit() {
        // Idle for 3 minutes when Mick quit, relaunched 3 minutes later: 6 minutes away.
        var s = state()
        let quitAt = t0.addingTimeInterval(40 * minute)
        SittingTimer.apply(.poll(idleSeconds: 3 * minute), config: config, now: quitAt, to: &s)
        let launch = quitAt.addingTimeInterval(3 * minute)
        #expect(SittingTimer.apply(.launch, config: config, now: launch, to: &s) == .relaunch(awaySeconds: 6 * minute))
        #expect(s.sittingSince == launch)
    }

    @Test func switchingUsersAwayForTheBreakResetResets() {
        var s = state()
        let resigned = t0.addingTimeInterval(30 * minute)
        let back = resigned.addingTimeInterval(5 * minute)
        #expect(SittingTimer.apply(.sessionBecameActive(resignedAt: resigned), config: config, now: back, to: &s) == .userSwitch(seconds: 5 * minute))
        #expect(s.sittingSince == back)
    }

    @Test func aQuickUserSwitchDoesNothing() {
        var s = state()
        let resigned = t0.addingTimeInterval(30 * minute)
        #expect(SittingTimer.apply(.sessionBecameActive(resignedAt: resigned), config: config, now: resigned.addingTimeInterval(4 * minute), to: &s) == nil)
        #expect(s.sittingSince == t0)
    }
}

@Suite struct SittingTimerNeverBackwardsTests {
    @Test func resetsNeverMoveSittingSinceBackwards() {
        // sitting_since is in the future (e.g. the clock was set back): nothing pulls it back.
        let future = t0.addingTimeInterval(60 * minute)
        let now = t0.addingTimeInterval(30 * minute)
        for input: SittingTimer.Input in [
            .poll(idleSeconds: 10 * minute), .launch,
            .wake(sleptAt: t0), .sessionBecameActive(resignedAt: t0),
        ] {
            var s = state(sittingSince: future, lastActiveAt: t0)
            #expect(SittingTimer.apply(input, config: config, now: now, to: &s) == nil)
            #expect(s.sittingSince == future)
        }
        #expect(SittingTimer.sittingSeconds(state(sittingSince: future), now: now) == 0)
    }

    @Test func randomSequencesNeverMoveSittingSinceBackwards() {
        var rng = SplitMix(seed: 0x5EED)
        for _ in 0..<200 {
            var s = state()
            var now = t0
            var previous = s.sittingSince
            for _ in 0..<100 {
                // Mostly forward, sometimes backwards (clock changes), in any order.
                now = now.addingTimeInterval(Double(rng.next(in: -600...1800)))
                let when = now.addingTimeInterval(Double(rng.next(in: -3600...600)))
                let input: SittingTimer.Input = switch rng.next(in: 0...3) {
                case 0: .poll(idleSeconds: Double(rng.next(in: -10...1200)))
                case 1: .launch
                case 2: .wake(sleptAt: rng.next(in: 0...4) == 0 ? nil : when)
                default: .sessionBecameActive(resignedAt: rng.next(in: 0...4) == 0 ? nil : when)
                }
                SittingTimer.apply(input, config: config, now: now, to: &s)
                #expect(s.sittingSince >= previous)
                previous = s.sittingSince
            }
        }
    }
}

@Suite struct SittingTimerIconTests {
    private func icon(_ s: MickState, at offset: TimeInterval, hooks: HooksStatus = .detected(lastEventAt: t0)) -> MenuBarIcon {
        let now = t0.addingTimeInterval(offset)
        return MenuBarIcon.current(hooks: hooks, state: s, config: config, now: now)
    }

    @Test func calmArmedGlaringByThreshold() {
        let s = state()
        #expect(icon(s, at: 0) == .calm)
        #expect(icon(s, at: 50 * minute - 1) == .calm)
        #expect(icon(s, at: 50 * minute) == .armed)
        #expect(icon(s, at: 100 * minute - 1) == .armed)
        #expect(icon(s, at: 100 * minute) == .glaring)
        #expect(icon(s, at: 300 * minute) == .glaring)
    }

    @Test func nagAfterHoldsTheIconCalmUntilItPasses() {
        // Ignored a reminder: nag_after 25 min out, even though sitting is past 2x.
        let nag = t0.addingTimeInterval(120 * minute)
        let s = state(nagAfter: nag)
        #expect(icon(s, at: 110 * minute) == .calm)
        #expect(icon(s, at: 120 * minute) == .glaring)
        let shortSit = state(nagAfter: t0.addingTimeInterval(60 * minute))
        #expect(icon(shortSit, at: 59 * minute) == .calm)
        #expect(icon(shortSit, at: 60 * minute) == .armed)
    }

    @Test func aPastNagAfterDoesNotBlock() {
        let s = state(nagAfter: t0.addingTimeInterval(-minute))
        #expect(icon(s, at: 50 * minute) == .armed)
    }

    @Test func warningOutranksTheSittingStates() {
        let s = state()
        #expect(icon(s, at: 120 * minute, hooks: .notDetected) == .warning)
        #expect(icon(s, at: 120 * minute, hooks: .stale(lastEventAt: t0)) == .warning)
    }

    @Test func respectsAConfiguredThreshold() {
        var custom = MickConfig.defaults
        custom.sitThresholdMinutes = 1
        let s = state()
        let hooks = HooksStatus.detected(lastEventAt: t0)
        #expect(MenuBarIcon.current(hooks: hooks, state: s, config: custom, now: t0.addingTimeInterval(59)) == .calm)
        #expect(MenuBarIcon.current(hooks: hooks, state: s, config: custom, now: t0.addingTimeInterval(60)) == .armed)
        #expect(MenuBarIcon.current(hooks: hooks, state: s, config: custom, now: t0.addingTimeInterval(120)) == .glaring)
    }
}

@Suite struct SittingTimerDetailLineTests {
    @Test func showsSittingTimeAndWhenTheReminderArms() {
        let s = state()
        #expect(SittingTimer.detailLine(s, config: config, now: t0.addingTimeInterval(47 * minute + 59)) == "Sitting 47m · reminder at 50m")
        #expect(SittingTimer.detailLine(s, config: config, now: t0) == "Sitting 0m · reminder at 50m")
    }

    @Test func reminderAtFollowsNagAfter() {
        // Sitting since t0, nag_after at 75 min: armed at 75 minutes of sitting.
        let s = state(nagAfter: t0.addingTimeInterval(75 * minute))
        #expect(SittingTimer.armedAt(s, config: config) == t0.addingTimeInterval(75 * minute))
        #expect(SittingTimer.detailLine(s, config: config, now: t0.addingTimeInterval(62 * minute)) == "Sitting 1h 2m · reminder at 1h 15m")
    }

    @Test func saysArmedOnceArmed() {
        let s = state()
        #expect(SittingTimer.detailLine(s, config: config, now: t0.addingTimeInterval(120 * minute)) == "Sitting 2h · reminder armed")
    }

    @Test func formatsMinutes() {
        #expect(SittingTimer.format(minutes: 0) == "0m")
        #expect(SittingTimer.format(minutes: 59) == "59m")
        #expect(SittingTimer.format(minutes: 60) == "1h")
        #expect(SittingTimer.format(minutes: 72) == "1h 12m")
        #expect(SittingTimer.format(minutes: -3) == "0m")
    }
}

/// Deterministic generator for the randomized test.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(nextRaw() % UInt64(range.count))
    }
}
