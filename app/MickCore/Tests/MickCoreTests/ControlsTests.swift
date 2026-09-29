import Foundation
import Testing
import MickCore

/// Snooze timing, pause, quiet hours and the icon (§6.4, §7), and Stretch now (§8).
@Suite struct ControlsTests {
    let config = MickConfig()  // 50 min threshold, 30 s delay

    func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }
    var utc: Calendar { calendar("UTC") }

    func at(_ day: Int, _ h: Int, _ m: Int, month: Int = 9, _ cal: Calendar? = nil) -> Date {
        (cal ?? utc).date(from: DateComponents(year: 2026, month: month, day: day, hour: h, minute: m))!
    }

    func armed(at now: Date, sittingMinutes: Double = 60) -> MickState {
        var s = MickState.defaults(now: now, calendar: utc)
        s.sittingSince = now.addingTimeInterval(-sittingMinutes * 60)
        s.lastEventAt = now
        return s
    }

    // MARK: - Snooze timing

    @Test func fixedSnoozesAddTheirDuration() {
        let now = at(29, 14, 7)
        #expect(SnoozeOption.thirtyMinutes.until(from: now, calendar: utc) == now.addingTimeInterval(1800))
        #expect(SnoozeOption.oneHour.until(from: now, calendar: utc) == now.addingTimeInterval(3600))
        #expect(SnoozeOption.twoHours.until(from: now, calendar: utc) == now.addingTimeInterval(7200))
    }

    @Test func untilTomorrowIsTheNextSixAMLocal() {
        let cal = calendar("America/Montevideo")
        // At 01:00, "tomorrow" means 06:00 the same day.
        #expect(SnoozeOption.untilTomorrow.until(from: at(29, 1, 0, cal), calendar: cal) == at(29, 6, 0, cal))
        #expect(SnoozeOption.untilTomorrow.until(from: at(29, 5, 59, cal), calendar: cal) == at(29, 6, 0, cal))
        // At or after 06:00, it's 06:00 the next day.
        #expect(SnoozeOption.untilTomorrow.until(from: at(29, 6, 0, cal), calendar: cal) == at(30, 6, 0, cal))
        #expect(SnoozeOption.untilTomorrow.until(from: at(29, 14, 30, cal), calendar: cal) == at(30, 6, 0, cal))
        #expect(SnoozeOption.untilTomorrow.until(from: at(29, 23, 59, cal), calendar: cal) == at(30, 6, 0, cal))
        // Month end.
        #expect(SnoozeOption.untilTomorrow.until(from: at(30, 22, 0, cal), calendar: cal) == at(1, 6, 0, month: 10, cal))
    }

    @Test func untilTomorrowIsLocalTimeAcrossADSTChange() {
        // Europe/Madrid moves to winter time on 25 October 2026 (03:00 -> 02:00).
        let cal = calendar("Europe/Madrid")
        let evening = at(24, 22, 0, month: 10, cal)
        let until = SnoozeOption.untilTomorrow.until(from: evening, calendar: cal)
        #expect(until == at(25, 6, 0, month: 10, cal))
        #expect(until.timeIntervalSince(evening) == 9 * 3600)  // 8 h of clock time + the repeated hour
        #expect(cal.component(.hour, from: until) == 6)
    }

    @Test func menuAndPanelOptions() {
        #expect(SnoozeOption.allCases.map(\.label) == ["30 minutes", "1 hour", "2 hours", "Until tomorrow (06:00)"])
        #expect(SnoozeOption.panelOptions == [.thirtyMinutes, .oneHour, .twoHours])
    }

    // MARK: - Snooze, pause and resume never touch the sitting timer

    @Test func controlsNeverResetTheSittingTimer() {
        let now = at(29, 14, 0)
        var s = armed(at: now)
        s.nagAfter = now.addingTimeInterval(600)
        let sitting = s.sittingSince
        Controls.snooze(&s, until: now.addingTimeInterval(3600))
        #expect(s.snoozedUntil == now.addingTimeInterval(3600))
        Controls.pause(&s)
        #expect(s.paused)
        Controls.resume(&s)
        #expect(!s.paused && s.snoozedUntil == nil)
        #expect(s.sittingSince == sitting)
        #expect(s.nagAfter == now.addingTimeInterval(600))
        #expect(s.today.ignored == 0)
    }

    @Test func expiredSnoozeClears() {
        let now = at(29, 14, 0)
        var s = armed(at: now)
        s.snoozedUntil = now.addingTimeInterval(60)
        #expect(Controls.isSnoozed(s, now: now))
        #expect(!Controls.clearExpiredSnooze(&s, now: now))
        #expect(!Controls.isSnoozed(s, now: now.addingTimeInterval(60)))
        #expect(Controls.clearExpiredSnooze(&s, now: now.addingTimeInterval(60)))
        #expect(s.snoozedUntil == nil)
    }

    // MARK: - Quiet hours

    @Test func quietHoursAcrossMidnight() {
        let q = QuietHours(start: "22:30", end: "06:15")
        #expect(q.contains(at(29, 22, 30), calendar: utc))
        #expect(q.contains(at(29, 23, 59), calendar: utc))
        #expect(q.contains(at(30, 0, 0), calendar: utc))
        #expect(q.contains(at(30, 6, 14), calendar: utc))
        #expect(!q.contains(at(30, 6, 15), calendar: utc))
        #expect(!q.contains(at(29, 22, 29), calendar: utc))
        #expect(!q.contains(at(29, 12, 0), calendar: utc))
        // Local time, not UTC.
        let cal = calendar("America/Montevideo")  // UTC-3
        #expect(q.contains(at(29, 23, 0, cal), calendar: cal))
        // 21:00 in Montevideo is 00:00 UTC: quiet in UTC, not locally.
        #expect(!q.contains(at(29, 21, 0, cal), calendar: cal))
        #expect(q.contains(at(29, 21, 0, cal), calendar: utc))
    }

    @Test func quietHoursBlockTriggersAcrossMidnight() {
        let quiet = MickConfig(quietHours: QuietHours(start: "22:00", end: "07:00"))
        for (day, h, m) in [(29, 22, 0), (29, 23, 45), (30, 0, 30), (30, 6, 59)] {
            let now = at(day, h, m)
            let s = armed(at: now)
            #expect(Reminder().blocker(s, config: quiet, now: now, calendar: utc) == .quietHours, "\(h):\(m)")
            var r = Reminder()
            var state = s
            let e = MickEvent(kind: .prompt, time: now.timeIntervalSince1970, sessionID: "A", cwd: "/tmp")
            guard case .applied(let change, let canTrigger) = SessionBook.apply(e, origin: .live, now: now, to: &state) else {
                Issue.record("event not applied"); continue
            }
            #expect(r.sessionChanged(change, sessionID: "A", canTrigger: canTrigger, state: state, config: quiet, now: now, calendar: utc)
                    == [.notScheduled(sessionID: "A", .quietHours)])
            #expect(r.phase == .idle)
        }
        for (day, h, m) in [(29, 21, 59), (30, 7, 0), (30, 12, 0)] {
            let now = at(day, h, m)
            #expect(Reminder().blocker(armed(at: now), config: quiet, now: now, calendar: utc) == nil, "\(h):\(m)")
        }
    }

    @Test func quietHoursStartingDuringTheShowDelayDropTheCheck() {
        let quiet = MickConfig(quietHours: QuietHours(start: "22:00", end: "07:00"))
        let now = at(29, 21, 59, 50)
        var state = armed(at: now)
        var r = Reminder()
        let e = MickEvent(kind: .prompt, time: now.timeIntervalSince1970, sessionID: "A", cwd: "/tmp")
        guard case .applied(let change, let canTrigger) = SessionBook.apply(e, origin: .live, now: now, to: &state) else {
            Issue.record("event not applied"); return
        }
        _ = r.sessionChanged(change, sessionID: "A", canTrigger: canTrigger, state: state, config: quiet, now: now, calendar: utc)
        #expect(r.check != nil)
        let later = now.addingTimeInterval(30)
        #expect(r.advance(state: state, config: quiet, now: later, idleSeconds: 10, calendar: utc)
                == [.dropped(sessionID: "A", .blocked(.quietHours))])
    }

    // MARK: - Icon

    @Test func iconShowsSnoozedAndPaused() {
        let now = at(29, 14, 0)
        func icon(_ s: MickState, _ c: MickConfig = MickConfig(), hooks: HooksStatus = .detected(lastEventAt: now)) -> MenuBarIcon {
            MenuBarIcon.current(hooks: hooks, state: s, config: c, now: now, calendar: utc)
        }
        var s = armed(at: now, sittingMinutes: 120)
        #expect(icon(s) == .glaring)
        s.snoozedUntil = now.addingTimeInterval(60)
        #expect(icon(s) == .snoozed)
        s.paused = true
        #expect(icon(s) == .paused)  // paused outranks snoozed
        #expect(icon(s, hooks: .notDetected) == .warning)  // a setup problem outranks both
        s.paused = false
        s.snoozedUntil = now  // ran out
        #expect(icon(s) == .glaring)
        // Quiet hours show the paused icon, even when calm.
        let calm = armed(at: now, sittingMinutes: 5)
        #expect(icon(calm) == .calm)
        #expect(icon(calm, MickConfig(quietHours: QuietHours(start: "13:00", end: "15:00"))) == .paused)
        #expect(icon(calm, MickConfig(quietHours: QuietHours(start: "23:00", end: "13:59"))) == .calm)
        let night = at(30, 2, 0)
        #expect(MenuBarIcon.current(hooks: .detected(lastEventAt: night), state: armed(at: night, sittingMinutes: 5),
                                    config: MickConfig(quietHours: QuietHours(start: "23:00", end: "07:00")), now: night, calendar: utc) == .paused)
    }

    // MARK: - Stretch now

    struct World {
        var state: MickState
        var reminder = Reminder()
        var config = MickConfig()
        var now: Date
        var idle: Double = 0
        var calendar: Calendar
        var effects: [Reminder.Effect] = []
        var settlements: [Settlement] = []

        mutating func take(_ new: [Reminder.Effect]) {
            effects += new
            for case .settled(let s) in new {
                let settlement = Settlement(s)
                settlement.apply(config: config, now: now, calendar: calendar, to: &state)
                settlements.append(settlement)
            }
        }

        mutating func stretch() -> Bool {
            let e = reminder.stretchNow(content: .standard, sittingMinutes: Int(SittingTimer.sittingSeconds(state, now: now) / 60), now: now)
            take(e)
            return !e.isEmpty
        }

        mutating func stretch(expect expected: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
            let shown = stretch()
            #expect(shown == expected, sourceLocation: sourceLocation)
        }

        mutating func event(_ kind: MickEvent.Kind, _ session: String) {
            let e = MickEvent(kind: kind, time: now.timeIntervalSince1970, sessionID: session, cwd: "/tmp")
            guard case .applied(let change, let canTrigger) = SessionBook.apply(e, origin: .live, now: now, to: &state) else { return }
            take(reminder.sessionChanged(change, sessionID: session, canTrigger: canTrigger, state: state, config: config, now: now, calendar: calendar))
        }

        mutating func run(for seconds: Int) {
            for _ in 0..<seconds {
                now = now.addingTimeInterval(1)
                take(reminder.advance(state: state, config: config, now: now, idleSeconds: idle, calendar: calendar))
            }
        }

        mutating func tick(_ i: Int) { take(reminder.setTicked(i, true, now: now)) }
        var closes: [Reminder.CloseReason] { effects.compactMap { if case .closed(_, let r) = $0 { r } else { nil } } }
        var last: Settlement? { settlements.last }
    }

    func world(sittingMinutes: Double = 30) -> World {
        let now = at(29, 14, 0)
        return World(state: armed(at: now, sittingMinutes: sittingMinutes), now: now, calendar: utc)
    }

    @Test func stretchNowShowsAManualPanelThatAgentStopsDontClose() {
        var w = world()
        w.event(.prompt, "A")  // not armed at 30 min: nothing scheduled
        #expect(w.reminder.phase == .idle)
        w.stretch(expect: true)
        let panel = try! #require(w.reminder.panel)
        #expect(panel.sessionID == nil && panel.isManual && panel.sittingMinutes == 30)
        w.event(.stop, "A")
        w.event(.prompt, "B")
        w.event(.wait, "B")
        w.event(.end, "B")
        #expect(w.reminder.panel != nil)
        #expect(w.closes.isEmpty)
    }

    @Test func stretchNowIsDisabledWhileAReminderIsScheduledVisibleOrSettling() {
        var w = world(sittingMinutes: 60)
        w.event(.prompt, "A")
        #expect(w.reminder.check != nil)
        #expect(!w.reminder.canStretchNow)
        w.stretch(expect: false)
        w.idle = 10
        w.run(for: 30)
        #expect(w.reminder.panel?.sessionID == "A")
        #expect(!w.reminder.canStretchNow)
        w.stretch(expect: false)
        #expect(w.reminder.panel?.sessionID == "A")
        w.event(.stop, "A")  // untouched: closes, then settles 3 min after it appeared
        #expect(w.reminder.settling != nil)
        #expect(!w.reminder.canStretchNow)
        w.stretch(expect: false)
        w.run(for: 180)
        #expect(w.reminder.phase == .idle)
        #expect(w.reminder.canStretchNow)
        w.stretch(expect: true)
        // And a visible Stretch now blocks it too.
        #expect(!w.reminder.canStretchNow)
    }

    @Test func stretchNowIsNotBlockedBySnoozePauseOrQuietHours() {
        var w = world()
        w.state.paused = true
        w.state.snoozedUntil = w.now.addingTimeInterval(3600)
        w.config.quietHours = QuietHours(start: "00:00", end: "23:59")
        w.stretch(expect: true)
    }

    @Test func untouchedStretchNowClosesAfterThreeMinutesAndIgnoredDoesNothing() {
        var w = world(sittingMinutes: 60)
        w.state.nagAfter = w.now.addingTimeInterval(-60)
        let before = w.state
        w.stretch(expect: true)
        w.run(for: 179)
        #expect(w.reminder.panel != nil)
        w.run(for: 1)
        #expect(w.closes == [.untouched])
        let s = try! #require(w.last)
        #expect(s.outcome == .ignored)
        #expect(s.record.manual)
        #expect(s.record.sessionID == nil)
        // Ignored does nothing for a manual reminder: no nag_after, no counter.
        #expect(w.state.sittingSince == before.sittingSince)
        #expect(w.state.nagAfter == before.nagAfter)
        #expect(w.state.today.ignored == 0)
        #expect(w.reminder.phase == .idle)
    }

    @Test func stretchNowClosedWithNothingTickedIsAlsoANoOp() {
        var w = world(sittingMinutes: 60)
        let before = w.state
        w.stretch(expect: true)
        w.run(for: 10)
        w.take(w.reminder.dismiss(now: w.now))
        #expect(w.closes == [.notNow])
        w.run(for: 170)
        #expect(w.last?.outcome == .ignored)
        #expect(w.state.today.ignored == 0 && w.state.nagAfter == nil && w.state.sittingSince == before.sittingSince)
    }

    @Test func stretchNowWithATickClosesTwoMinutesAfterTheLastTickAndResetsSitting() {
        var w = world(sittingMinutes: 60)
        w.stretch(expect: true)
        w.run(for: 20)
        w.tick(0)
        w.run(for: 119)
        #expect(w.reminder.panel != nil)
        w.run(for: 1)
        #expect(w.closes == [.afterLastTick])
        // Closed at 140 s; settles at 180 s after it appeared.
        #expect(w.settlements.isEmpty)
        w.run(for: 40)
        let s = try! #require(w.last)
        #expect(s.outcome == .partial && s.record.manual)
        #expect(w.state.sittingSince == s.settling.until)
    }

    @Test func stretchNowAllTickedClosesAfterTheDoneLineAsCompleted() {
        var w = world(sittingMinutes: 60)
        w.state.nagAfter = w.now.addingTimeInterval(600)
        w.stretch(expect: true)
        w.run(for: 5)
        w.tick(0); w.tick(1); w.tick(2)
        w.run(for: 3)
        #expect(w.closes == [.done])
        w.run(for: 172)
        let s = try! #require(w.last)
        #expect(s.outcome == .completed && s.record.manual)
        #expect(w.state.sittingSince == s.settling.until)
        #expect(w.state.nagAfter == nil)
    }

    @Test func stretchNowStoodUpResetsSitting() {
        var w = world(sittingMinutes: 60)
        w.stretch(expect: true)
        for _ in 0..<36 {
            w.run(for: 5)
            w.idle += 5
        }
        let s = try! #require(w.last)
        #expect(s.outcome == .stoodUp && s.record.manual)
        #expect(w.state.sittingSince == s.settling.until)
    }

    @Test func stretchNowBlocksPromptsWhileVisibleAndSettling() {
        var w = world(sittingMinutes: 60)
        w.stretch(expect: true)
        w.event(.prompt, "A")
        #expect(w.effects.last == .notScheduled(sessionID: "A", .busy))
    }
}

private extension ControlsTests {
    func at(_ day: Int, _ h: Int, _ m: Int, _ s: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m, second: s))!
    }
}
