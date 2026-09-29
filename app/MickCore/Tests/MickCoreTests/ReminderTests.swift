import Foundation
import Testing
import MickCore

/// Trigger decisions (§7), check hand-off and re-prompts (§6.3), panel lifetime (§9.2).
/// Everything is driven by hand-set times; nothing sleeps.
@Suite struct ReminderTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let config = MickConfig()  // 50 min threshold, 30 s delay
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// A world with a state, the reminder machine and a clock.
    struct World {
        var state: MickState
        var reminder = Reminder()
        var config: MickConfig
        var now: Date
        var idle: Double = 10
        var calendar: Calendar
        var effects: [Reminder.Effect] = []

        mutating func event(_ kind: MickEvent.Kind, _ session: String, live: Bool = true, cwd: String = "/tmp/p") {
            // Two events for one session at the same instant would be dropped as out of
            // order (§6.3); give the later one a millisecond more.
            var t = now.timeIntervalSince1970
            if let last = state.sessions[session]?.lastEventAt.timeIntervalSince1970, last >= t { t = last + 0.001 }
            let e = MickEvent(kind: kind, time: t, sessionID: session, cwd: cwd)
            guard case .applied(let change, let canTrigger) = SessionBook.apply(e, origin: live ? .live : .backlog, now: now, to: &state) else { return }
            effects += reminder.sessionChanged(change, sessionID: session, canTrigger: canTrigger, state: state, config: config, now: now, calendar: calendar)
        }

        mutating func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            effects += reminder.advance(state: state, config: config, now: now, idleSeconds: idle, calendar: calendar)
        }

        /// Moves time forward one second at a time, running timers as the app would.
        mutating func run(for seconds: Int) {
            for _ in 0..<seconds { advance(1) }
        }

        mutating func tick(_ i: Int, _ on: Bool = true) {
            effects += reminder.setTicked(i, on, now: now)
        }

        var shows: Int { effects.filter { if case .show = $0 { true } else { false } }.count }
        var closes: [Reminder.CloseReason] {
            effects.compactMap { if case .closed(_, let r) = $0 { r } else { nil } }
        }
        var isVisible: Bool { reminder.panel != nil }
    }

    func world(sittingMinutes: Double = 60, config: MickConfig? = nil) -> World {
        var s = MickState.defaults(now: t0, calendar: utc)
        s.sittingSince = t0.addingTimeInterval(-sittingMinutes * 60)
        return World(state: s, config: config ?? self.config, now: t0, calendar: utc)
    }

    // MARK: - Scheduling (§7)

    @Test func livePromptWhenArmedSchedulesACheckAfterTheShowDelay() {
        var w = world()
        w.event(.prompt, "A")
        #expect(w.reminder.check == Reminder.Check(sessionID: "A", fireAt: t0.addingTimeInterval(30)))
        #expect(w.effects == [.scheduled(sessionID: "A", fireAt: t0.addingTimeInterval(30), handedOffFrom: nil)])
        #expect(w.reminder.nextDeadline == t0.addingTimeInterval(30))
    }

    @Test func notArmedDoesNotSchedule() {
        var w = world(sittingMinutes: 49)
        w.event(.prompt, "A")
        #expect(w.reminder.phase == .idle)
        #expect(w.effects == [.notScheduled(sessionID: "A", .notArmed)])
    }

    @Test func exactlyAtTheThresholdSchedules() {
        var w = world(sittingMinutes: 50)
        w.event(.prompt, "A")
        #expect(w.reminder.check != nil)
    }

    @Test func nagAfterInTheFutureBlocksAndPastPasses() {
        var w = world()
        w.state.nagAfter = t0.addingTimeInterval(60)
        w.event(.prompt, "A")
        #expect(w.effects == [.notScheduled(sessionID: "A", .notArmed)])
        w.event(.stop, "A")
        w.now = t0.addingTimeInterval(61)
        w.event(.prompt, "A")
        #expect(w.reminder.check?.sessionID == "A")
    }

    @Test func snoozedPausedAndQuietHoursBlock() {
        var snoozed = world()
        snoozed.state.snoozedUntil = t0.addingTimeInterval(60)
        snoozed.event(.prompt, "A")
        #expect(snoozed.effects == [.notScheduled(sessionID: "A", .snoozed)])

        var expired = world()
        expired.state.snoozedUntil = t0.addingTimeInterval(-1)
        expired.event(.prompt, "A")
        #expect(expired.reminder.check != nil)

        var paused = world()
        paused.state.paused = true
        paused.event(.prompt, "A")
        #expect(paused.effects == [.notScheduled(sessionID: "A", .paused)])

        // t0 is 14:13 UTC.
        var quiet = world(config: MickConfig(quietHours: QuietHours(start: "14:00", end: "15:00")))
        quiet.event(.prompt, "A")
        #expect(quiet.effects == [.notScheduled(sessionID: "A", .quietHours)])

        var outside = world(config: MickConfig(quietHours: QuietHours(start: "22:00", end: "07:00")))
        outside.event(.prompt, "A")
        #expect(outside.reminder.check != nil)
    }

    @Test func backlogPromptNeverSchedules() {
        var w = world()
        w.event(.prompt, "A", live: false)
        #expect(w.reminder.phase == .idle)
        #expect(w.effects.isEmpty)
        #expect(w.state.sessions["A"]?.running == true)
    }

    @Test func nothingScheduledWhileAnotherCheckIsScheduled() {
        var w = world()
        w.event(.prompt, "A")
        w.event(.prompt, "B")
        #expect(w.reminder.check?.sessionID == "A")
        #expect(w.effects.last == .notScheduled(sessionID: "B", .busy))
    }

    @Test func nothingScheduledWhileVisibleOrSettling() {
        var w = world()
        w.event(.prompt, "A")
        w.advance(30)
        #expect(w.isVisible)
        w.event(.prompt, "B")
        #expect(w.effects.last == .notScheduled(sessionID: "B", .busy))
        w.event(.stop, "A")  // nothing ticked: closes, then settles until shown + 3 min
        #expect(w.reminder.settling != nil)
        w.advance(60)
        w.event(.prompt, "C")
        #expect(w.effects.last == .notScheduled(sessionID: "C", .busy))
        #expect(w.reminder.check == nil)
    }

    // MARK: - Show time (§7)

    @Test func showsAfterTheDelayIfStillRunning() {
        var w = world()
        w.event(.prompt, "A", cwd: "/work/proj")
        w.advance(29.9)
        #expect(!w.isVisible)
        w.advance(0.1)
        #expect(w.isVisible)
        #expect(w.reminder.panel?.sessionID == "A")
        #expect(w.reminder.panel?.cwd == "/work/proj")
        #expect(w.reminder.panel?.shownAt == t0.addingTimeInterval(30))
        #expect(w.reminder.panel?.content == .standard)
    }

    @Test func runsShorterThanTheShowDelayNeverProduceAReminder() {
        for stopAfter in [0.5, 5, 29.9] {
            for kind in [MickEvent.Kind.stop, .wait, .end] {
                var w = world()
                w.event(.prompt, "A")
                w.now = t0.addingTimeInterval(stopAfter)
                w.event(kind, "A")
                w.run(for: 120)
                #expect(w.shows == 0, "\(kind) after \(stopAfter)s")
                #expect(w.reminder.phase == .idle)
            }
        }
    }

    @Test func stoppedByShowTimeWithoutAStopEventIsDropped() {
        // Defensive: the session record says not running (e.g. pruned) at show time.
        var w = world()
        w.event(.prompt, "A")
        w.state.sessions["A"]?.running = false
        w.advance(30)
        #expect(w.shows == 0)
        #expect(w.effects.last == .dropped(sessionID: "A", .sessionStopped))
    }

    @Test func snoozedOrPausedByShowTimeDrops() {
        var w = world()
        w.event(.prompt, "A")
        w.state.paused = true
        w.advance(30)
        #expect(w.shows == 0)
        #expect(w.effects.last == .dropped(sessionID: "A", .blocked(.paused)))
        #expect(w.reminder.phase == .idle)
    }

    @Test func waitsForAThreeSecondInputGap() {
        var w = world()
        w.idle = 0.5
        w.event(.prompt, "A")
        w.advance(30)
        #expect(!w.isVisible)
        #expect(w.effects.last == .waitingForGap(sessionID: "A"))
        #expect(w.reminder.nextDeadline == t0.addingTimeInterval(31))
        w.run(for: 5)
        #expect(!w.isVisible)
        w.idle = 2.9
        w.advance(1)
        #expect(!w.isVisible)
        w.idle = 3
        w.advance(1)
        #expect(w.isVisible)
        #expect(w.reminder.panel?.shownAt == t0.addingTimeInterval(37))
        #expect(w.effects.filter { $0 == .waitingForGap(sessionID: "A") }.count == 1)
    }

    @Test func givesUpAfterThirtySecondsWithoutAGapWithNoPenalty() {
        var w = world()
        w.idle = 0.2
        w.event(.prompt, "A")
        let before = w.state
        w.run(for: 30)  // first attempt at +30
        #expect(!w.isVisible)
        w.run(for: 29)
        #expect(w.reminder.check != nil)
        w.run(for: 1)  // +60: 30 s after the first attempt
        #expect(w.reminder.phase == .idle)
        #expect(w.effects.last == .dropped(sessionID: "A", .noInputGap))
        #expect(w.shows == 0)
        // No penalty: state untouched, still armed, the next prompt schedules again.
        #expect(w.state.nagAfter == before.nagAfter && w.state.sittingSince == before.sittingSince)
        w.idle = 10
        w.event(.prompt, "A")
        #expect(w.reminder.check?.sessionID == "A")
    }

    @Test func stopDuringTheGapWaitCancelsTheCheck() {
        var w = world()
        w.idle = 0
        w.event(.prompt, "A")
        w.run(for: 32)
        #expect(w.reminder.check?.isWaitingForGap == true)
        w.event(.wait, "A")
        #expect(w.reminder.phase == .idle)
        w.idle = 10
        w.run(for: 60)
        #expect(w.shows == 0)
    }

    // MARK: - Re-prompts and hand-off (§6.3)

    @Test func aSecondPromptOnTheSameSessionReschedules() {
        var w = world()
        w.event(.prompt, "A")
        w.run(for: 20)
        w.event(.prompt, "A")
        #expect(w.effects.last == .rescheduled(sessionID: "A", fireAt: t0.addingTimeInterval(50)))
        w.run(for: 29)
        #expect(!w.isVisible)
        w.run(for: 1)
        #expect(w.isVisible)
        #expect(w.shows == 1)
    }

    @Test func aRepromptDuringTheGapWaitRestartsTheDelay() {
        var w = world()
        w.idle = 0
        w.event(.prompt, "A")
        w.run(for: 35)
        w.event(.prompt, "A")
        #expect(w.reminder.check == Reminder.Check(sessionID: "A", fireAt: t0.addingTimeInterval(65)))
    }

    @Test func aRepromptLeavesAVisiblePanelAlone() {
        var w = world()
        w.event(.prompt, "A")
        w.run(for: 30)
        w.run(for: 10)
        let panel = w.reminder.panel  // after the runs: the idle watch updates it
        w.event(.prompt, "A")
        #expect(w.reminder.panel == panel)
    }

    @Test func stoppedSessionHandsItsCheckToTheMostRecentlyStartedRunningSession() {
        var w = world()
        w.event(.prompt, "A")      // gets the check (fires at +30)
        w.now = t0.addingTimeInterval(5)
        w.event(.prompt, "B")      // started +5
        w.now = t0.addingTimeInterval(10)
        w.event(.prompt, "C")      // started +10: the most recent
        w.now = t0.addingTimeInterval(12)
        w.event(.stop, "A")
        #expect(w.effects.last == .scheduled(sessionID: "C", fireAt: t0.addingTimeInterval(40), handedOffFrom: "A"))
        w.advance(28)
        #expect(w.reminder.panel?.sessionID == "C")
    }

    @Test func handOffFiresNowWhenTheOtherRunIsAlreadyPastTheDelay() {
        // B has been running for 11 minutes when A, which holds the check, ends.
        var v = world(sittingMinutes: 40)
        v.event(.prompt, "B")      // not armed yet: nothing scheduled
        v.now = t0.addingTimeInterval(11 * 60)
        v.event(.prompt, "A")      // armed now
        v.now = v.now.addingTimeInterval(5)
        v.event(.end, "A")
        #expect(v.effects.last == .scheduled(sessionID: "B", fireAt: v.now, handedOffFrom: "A"))
        v.advance(0)
        #expect(v.reminder.panel?.sessionID == "B")
    }

    @Test func handOffReevaluatesTheTriggerConditions() {
        var w = world()
        w.event(.prompt, "A")
        w.event(.prompt, "B")
        w.state.paused = true
        w.event(.stop, "A")
        #expect(w.reminder.phase == .idle)
        #expect(w.effects.last == .dropped(sessionID: "A", .sessionStopped))
    }

    @Test func noHandOffWithoutAnotherRunningSession() {
        var w = world()
        w.event(.prompt, "A")
        w.event(.prompt, "B")
        w.event(.stop, "B")        // B had no check
        #expect(w.reminder.check?.sessionID == "A")
        w.event(.stop, "A")
        #expect(w.reminder.phase == .idle)
        #expect(w.effects.last == .dropped(sessionID: "A", .sessionStopped))
    }

    @Test func threeConcurrentSessionsNeverProduceMoreThanOneReminder() {
        var w = world()
        w.event(.prompt, "A")
        w.now = t0.addingTimeInterval(3); w.event(.prompt, "B")
        w.now = t0.addingTimeInterval(6); w.event(.prompt, "C")
        w.run(for: 30)
        #expect(w.shows == 1)
        // Stops, re-prompts and more prompts while the panel is up or settling.
        w.event(.stop, "B"); w.event(.prompt, "B"); w.event(.prompt, "C")
        w.run(for: 5)
        w.event(.stop, "A")  // the panel's session: closes, then settles
        w.event(.prompt, "A")
        w.run(for: 100)
        #expect(w.shows == 1)
        #expect(w.closes == [.agentStopped])
    }

    // MARK: - Panel lifetime (§9.2)

    func shown(_ w: inout World) {
        w.event(.prompt, "A")
        w.advance(30)
        precondition(w.isVisible)
    }

    @Test func nothingTickedClosesImmediatelyOnStopWaitOrEnd() {
        for kind in [MickEvent.Kind.stop, .wait, .end] {
            var w = world()
            shown(&w)
            w.run(for: 20)
            w.event(kind, "A")
            #expect(w.closes == [.agentStopped], "\(kind)")
            #expect(w.reminder.settling?.closedAt == w.now)
        }
    }

    @Test func anotherSessionStoppingLeavesThePanelUp() {
        var w = world()
        w.event(.prompt, "B")
        shown(&w)  // check belonged to B
        #expect(w.reminder.panel?.sessionID == "B")
        w.event(.prompt, "A")
        w.event(.stop, "A")
        #expect(w.isVisible)
    }

    @Test func untouchedClosesAfterThreeMinutes() {
        var w = world()
        shown(&w)
        let shownAt = w.now
        #expect(w.reminder.nextDeadline == shownAt.addingTimeInterval(180))
        w.run(for: 179)
        #expect(w.isVisible)
        w.run(for: 1)
        #expect(w.closes == [.untouched])
        // Settles immediately: the panel was up for the whole settle window.
        #expect(w.reminder.phase == .idle)
        #expect(w.effects.contains { if case .settled = $0 { true } else { false } })
    }

    @Test func withATickItStaysAfterTheAgentStopsUntilTwoMinutesAfterTheLastTick() {
        var w = world()
        shown(&w)
        w.run(for: 10)
        w.tick(0)
        w.run(for: 5)
        w.event(.stop, "A")
        #expect(w.isVisible)
        w.run(for: 100)
        w.tick(1)                      // last tick at shown + 115
        let lastTick = w.now
        w.run(for: 119)
        #expect(w.isVisible)
        w.run(for: 1)
        #expect(w.closes == [.afterLastTick])
        // Up for more than 3 minutes, so it settles as it closes.
        let settled = w.effects.compactMap { if case .settled(let s) = $0 { s } else { nil } }
        #expect(settled.map(\.closedAt) == [lastTick.addingTimeInterval(120)])
        #expect(settled.first?.panel.tickedItemIDs == ["stand", "back-bend"])
        #expect(w.reminder.phase == .idle)
    }

    @Test func aTickKeepsItPastTheUntouchedTimeout() {
        var w = world()
        shown(&w)
        w.run(for: 170)
        w.tick(0)
        w.run(for: 60)
        #expect(w.isVisible)
    }

    @Test func untickingEverythingFallsBackToTheUntouchedRules() {
        var w = world()
        shown(&w)
        w.run(for: 10)
        w.tick(0)
        w.tick(0, false)
        #expect(w.reminder.panel?.ticked.isEmpty == true)
        w.event(.stop, "A")
        #expect(w.closes == [.agentStopped])
    }

    @Test func allTickedShowsTheDoneLineForThreeSeconds() {
        var w = world()
        shown(&w)
        w.tick(0); w.tick(1)
        w.run(for: 5)
        w.tick(2)
        #expect(w.effects.contains { if case .allTicked = $0 { true } else { false } })
        #expect(w.reminder.panel?.isDone == true)
        #expect(w.reminder.panel?.tickedItemIDs == ["stand", "back-bend", "shoulder-rolls"])
        // Ticks are frozen and a stop doesn't cut the done line short.
        w.tick(0, false)
        #expect(w.reminder.panel?.ticked.count == 3)
        w.event(.stop, "A")
        w.run(for: 2)
        #expect(w.isVisible)
        w.run(for: 1)
        #expect(w.closes == [.done])
        // Closed at shown + 8 s: settles 3 minutes after it was shown.
        #expect(w.reminder.settling?.until == t0.addingTimeInterval(30 + 180))
    }

    @Test func hardCapClosesTenMinutesAfterAppearing() {
        var w = world()
        shown(&w)
        for _ in 0..<10 {
            w.run(for: 55)
            w.tick(0, w.reminder.panel?.ticked.contains(0) != true)
            if w.reminder.panel?.ticked.isEmpty == true { w.tick(1) }
        }
        #expect(w.isVisible)  // 550 s in, ticks keep it alive
        w.run(for: 49)
        #expect(w.isVisible)
        w.run(for: 1)
        #expect(w.closes == [.hardCap])
    }

    @Test func notNowClosesAndSettlesThreeMinutesAfterShown() {
        var w = world()
        shown(&w)
        w.run(for: 10)
        w.effects += w.reminder.dismiss(now: w.now)
        #expect(w.closes == [.notNow])
        #expect(w.reminder.settling?.until == t0.addingTimeInterval(210))
        #expect(w.reminder.nextDeadline == t0.addingTimeInterval(210))
        w.run(for: 169)
        #expect(w.reminder.settling != nil)
        w.run(for: 1)
        #expect(w.reminder.phase == .idle)
        // Free again: the next live prompt schedules (outcomes arrive with #7).
        w.event(.prompt, "A")
        #expect(w.reminder.check != nil)
    }

    @Test func togglesOutsideAVisiblePanelAreIgnored() {
        var w = world()
        #expect(w.reminder.setTicked(0, true, now: t0).isEmpty)
        shown(&w)
        #expect(w.reminder.setTicked(7, true, now: w.now).isEmpty)
        #expect(w.reminder.setTicked(0, false, now: w.now).isEmpty)  // already off
    }

    // MARK: - Activity assertion (§6.3)

    @Test func activityNeededWhileRunningScheduledVisibleOrSettling() {
        var w = world(sittingMinutes: 0)
        #expect(!w.reminder.needsActivity(w.state))
        w.event(.prompt, "A")              // not armed: running only
        #expect(w.reminder.check == nil)
        #expect(w.reminder.needsActivity(w.state))
        w.event(.stop, "A")
        #expect(!w.reminder.needsActivity(w.state))

        var v = world()
        v.event(.prompt, "A")
        v.state.sessions["A"]?.running = false  // scheduled, nothing running
        #expect(v.reminder.needsActivity(v.state))
        v.state.sessions["A"]?.running = true
        v.advance(30)
        v.state.sessions["A"]?.running = false  // visible
        #expect(v.reminder.needsActivity(v.state))
        v.effects += v.reminder.dismiss(now: v.now)  // settling
        #expect(v.reminder.needsActivity(v.state))
        v.run(for: 180)
        #expect(v.reminder.phase == .idle)
        #expect(!v.reminder.needsActivity(v.state))
    }

    // MARK: - Quiet hours

    @Test func quietHoursContainment() {
        func at(_ h: Int, _ m: Int) -> Date {
            utc.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: h, minute: m))!
        }
        let day = QuietHours(start: "09:00", end: "17:30")
        #expect(day.contains(at(9, 0), calendar: utc))
        #expect(day.contains(at(17, 29), calendar: utc))
        #expect(!day.contains(at(17, 30), calendar: utc))
        #expect(!day.contains(at(8, 59), calendar: utc))
        let night = QuietHours(start: "22:00", end: "07:00")
        #expect(night.contains(at(23, 0), calendar: utc))
        #expect(night.contains(at(0, 0), calendar: utc))
        #expect(night.contains(at(6, 59), calendar: utc))
        #expect(!night.contains(at(7, 0), calendar: utc))
        #expect(!night.contains(at(12, 0), calendar: utc))
        #expect(!QuietHours(start: "10:00", end: "10:00").contains(at(10, 0), calendar: utc))
        #expect(!QuietHours(start: "nope", end: "10:00").contains(at(9, 0), calendar: utc))
    }
}
