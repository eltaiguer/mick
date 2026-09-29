import Foundation
import Testing
import MickCore

/// Reminder outcomes and Mick's memory (§8): the idle watch, the outcome table, what
/// each outcome does to `sitting_since` / `nag_after` / `ignored_today`, midnight
/// rollover and the reminder log line (§12.3). Driven by hand-set times.
@Suite struct OutcomeTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13:20 UTC
    let config = MickConfig()  // 50 min threshold, 30 s delay
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// The reminder machine plus state, with outcomes applied on settle the way the
    /// engine does it.
    struct World {
        var state: MickState
        var reminder = Reminder()
        var config: MickConfig
        var now: Date
        var idle: Double = 10
        var calendar: Calendar
        var effects: [Reminder.Effect] = []
        var settlements: [Settlement] = []

        mutating func event(_ kind: MickEvent.Kind, _ session: String, cwd: String = "/tmp/p") {
            var t = now.timeIntervalSince1970
            if let last = state.sessions[session]?.lastEventAt.timeIntervalSince1970, last >= t { t = last + 0.001 }
            let e = MickEvent(kind: kind, time: t, sessionID: session, cwd: cwd)
            guard case .applied(let change, let canTrigger) = SessionBook.apply(e, origin: .live, now: now, to: &state) else { return }
            take(reminder.sessionChanged(change, sessionID: session, canTrigger: canTrigger, state: state, config: config, now: now, calendar: calendar))
        }

        /// One second at a time, polling idle every 5 s as the engine does during the
        /// follow-up window, and running the reminder timers.
        mutating func run(for seconds: Int) {
            for _ in 0..<seconds {
                now = now.addingTimeInterval(1)
                if Int(now.timeIntervalSince1970) % 5 == 0 {
                    SittingTimer.apply(.poll(idleSeconds: idle), config: config, now: now, to: &state)
                    reminder.observeIdle(idle, now: now)
                }
                take(reminder.advance(state: state, config: config, now: now, idleSeconds: idle, calendar: calendar))
            }
        }

        mutating func tick(_ i: Int, _ on: Bool = true) { take(reminder.setTicked(i, on, now: now)) }
        mutating func notNow() { take(reminder.dismiss(now: now)) }
        mutating func snooze() { take(reminder.snooze(now: now)) }

        private mutating func take(_ new: [Reminder.Effect]) {
            effects += new
            for case .settled(let s) in new {
                let settlement = Settlement(s)
                settlement.apply(config: config, now: now, calendar: calendar, to: &state)
                settlements.append(settlement)
            }
        }

        /// Prompt, wait out the show delay, and return with the panel visible.
        mutating func showReminder(_ session: String = "A") {
            let shows = effects.filter { if case .show = $0 { true } else { false } }.count
            event(.prompt, session)
            run(for: config.showDelaySeconds)
            precondition(effects.filter { if case .show = $0 { true } else { false } }.count == shows + 1, "no reminder shown")
        }

        var last: Settlement? { settlements.last }
        var sittingMinutes: Double { SittingTimer.sittingSeconds(state, now: now) / 60 }
        var armed: Bool { SittingTimer.isArmed(state, config: config, now: now) }
    }

    func world(sittingMinutes: Double = 60) -> World {
        var s = MickState.defaults(now: t0, calendar: utc)
        s.sittingSince = t0.addingTimeInterval(-sittingMinutes * 60)
        return World(state: s, config: config, now: t0, calendar: utc)
    }

    private func settling(ticked: Set<Int> = [], maxIdle: Double = 0, reason: Reminder.CloseReason = .notNow, session: String? = "A") -> Reminder.Settling {
        var p = Reminder.Panel(sessionID: session, cwd: "/tmp/p", content: .standard, shownAt: t0, sittingMinutes: 54)
        p.ticked = ticked
        p.maxIdleSeconds = maxIdle
        return Reminder.Settling(panel: p, closedAt: t0.addingTimeInterval(60), reason: reason, until: t0.addingTimeInterval(180))
    }

    // MARK: - The table, first match wins

    @Test func judgedTopToBottom() {
        #expect(Outcome.judge(settling(ticked: [0, 1, 2])) == .completed)
        #expect(Outcome.judge(settling(ticked: [0, 1, 2], maxIdle: 300)) == .completed)
        #expect(Outcome.judge(settling(ticked: [1])) == .partial)
        #expect(Outcome.judge(settling(ticked: [0, 2], maxIdle: 120)) == .partial)
        #expect(Outcome.judge(settling(maxIdle: 60)) == .stoodUp)
        #expect(Outcome.judge(settling(maxIdle: 59.9)) == .ignored)
        #expect(Outcome.judge(settling()) == .ignored)
        // Snoozed is matched first, even with ticks or a long idle stretch.
        #expect(Outcome.judge(settling(ticked: [0, 1, 2], maxIdle: 300, reason: .snoozed)) == .snoozed)
        #expect(Outcome.judge(settling(reason: .snoozed)) == .snoozed)
    }

    @Test func notNowAndOtherEmptyClosesAreJudgedByTheSameTable() {
        for reason: Reminder.CloseReason in [.notNow, .agentStopped, .untouched, .hardCap] {
            #expect(Outcome.judge(settling(reason: reason)) == .ignored)
            #expect(Outcome.judge(settling(maxIdle: 90, reason: reason)) == .stoodUp)
        }
    }

    // MARK: - Effects

    @Test func completedPartialAndStoodUpMoveSittingSinceToTheSettleTime() {
        for outcome: Outcome in [.completed, .partial, .stoodUp] {
            var s = MickState.defaults(now: t0, calendar: utc)
            s.sittingSince = t0.addingTimeInterval(-3600)
            s.nagAfter = t0.addingTimeInterval(-10)
            let settledAt = t0.addingTimeInterval(180)
            outcome.apply(settledAt: settledAt, manual: false, config: config, now: settledAt, calendar: utc, to: &s)
            #expect(s.sittingSince == settledAt, "\(outcome)")
            #expect(s.nagAfter == nil, "\(outcome)")
            #expect(s.today.ignored == 0, "\(outcome)")
        }
    }

    @Test func settlingNeverMovesSittingSinceBackwards() {
        var s = MickState.defaults(now: t0, calendar: utc)
        s.sittingSince = t0.addingTimeInterval(600)  // a wake reset after the settle time
        Outcome.completed.apply(settledAt: t0, manual: false, config: config, now: t0.addingTimeInterval(700), calendar: utc, to: &s)
        #expect(s.sittingSince == t0.addingTimeInterval(600))
    }

    @Test func ignoredSetsNagAfterHalfAThresholdLaterAndCounts() {
        var s = MickState.defaults(now: t0, calendar: utc)
        let since = t0.addingTimeInterval(-3600)
        s.sittingSince = since
        let settledAt = t0.addingTimeInterval(180)
        Outcome.ignored.apply(settledAt: settledAt, manual: false, config: config, now: settledAt, calendar: utc, to: &s)
        #expect(s.sittingSince == since)
        #expect(s.nagAfter == settledAt.addingTimeInterval(25 * 60))
        #expect(s.today.ignored == 1)
        // Follows a configured threshold.
        var c = config
        c.sitThresholdMinutes = 30
        Outcome.ignored.apply(settledAt: settledAt, manual: false, config: c, now: settledAt, calendar: utc, to: &s)
        #expect(s.nagAfter == settledAt.addingTimeInterval(15 * 60))
        #expect(s.today.ignored == 2)
    }

    @Test func snoozedChangesNothingButClearsNagAfter() {
        var s = MickState.defaults(now: t0, calendar: utc)
        s.sittingSince = t0.addingTimeInterval(-3600)
        s.nagAfter = t0.addingTimeInterval(-10)
        s.today.ignored = 2
        Outcome.snoozed.apply(settledAt: t0, manual: false, config: config, now: t0, calendar: utc, to: &s)
        #expect(s.sittingSince == t0.addingTimeInterval(-3600))
        #expect(s.nagAfter == nil)
        #expect(s.today.ignored == 2)
    }

    @Test func manualIgnoredDoesNothing() {
        var s = MickState.defaults(now: t0, calendar: utc)
        s.sittingSince = t0.addingTimeInterval(-3600)
        let before = s
        Outcome.ignored.apply(settledAt: t0, manual: true, config: config, now: t0, calendar: utc, to: &s)
        #expect(s == before)
        // Other manual outcomes have the normal timer effects.
        Outcome.partial.apply(settledAt: t0, manual: true, config: config, now: t0, calendar: utc, to: &s)
        #expect(s.sittingSince == t0)
    }

    // MARK: - Through the reminder lifecycle

    @Test func stopWithNothingTickedSettlesThreeMinutesAfterShownAsIgnored() {
        var w = world()
        w.showReminder()
        let shownAt = w.now
        w.run(for: 20)
        w.event(.stop, "A")
        #expect(w.reminder.settling != nil)
        #expect(w.settlements.isEmpty)
        w.run(for: 159)
        #expect(w.settlements.isEmpty)
        w.run(for: 1)
        let settled = shownAt.addingTimeInterval(180)
        #expect(w.last?.outcome == .ignored)
        #expect(w.last?.settling.until == settled)
        #expect(w.state.nagAfter == settled.addingTimeInterval(25 * 60))
        #expect(w.state.today.ignored == 1)
        #expect(w.state.sittingSince == t0.addingTimeInterval(-3600))
    }

    @Test func notNowWithNothingTickedIsIgnoredToo() {
        var w = world()
        w.showReminder()
        w.run(for: 5)
        w.notNow()
        w.run(for: 180)
        #expect(w.last?.outcome == .ignored)
        #expect(w.last?.settling.reason == .notNow)
    }

    @Test func aMinuteOfIdleAfterTheCloseCountsAsStoodUp() {
        var w = world()
        w.showReminder()
        w.notNow()
        w.run(for: 30)
        w.idle = 0
        w.run(for: 5)
        // Walk away: idle grows with the clock for the rest of the window.
        for _ in 0..<70 { w.idle += 1; w.run(for: 1) }
        w.run(for: 180)
        #expect(w.last?.outcome == .stoodUp)
        #expect((w.last?.settling.panel.maxIdleSeconds ?? 0) >= 60)
        #expect(w.state.sittingSince == w.last?.settling.until)
        #expect(w.state.nagAfter == nil)
        #expect(w.state.today.ignored == 0)
    }

    @Test func idleFromBeforeThePanelAppearedDoesNotCount() {
        var w = world()
        w.showReminder()
        // A reading taken 10 s after it appeared that says 50 s idle: only 10 s count.
        w.run(for: 10)
        w.reminder.observeIdle(50, now: w.now)
        #expect(w.reminder.panel?.maxIdleSeconds == 10)
    }

    @Test func idleAfterTheSettleTimeDoesNotCount() {
        var w = world()
        w.showReminder()
        let shownAt = w.now
        w.notNow()
        // A late reading at shown + 4 min saying idle 150 s: only the part before the
        // settle time (shown + 3 min) counts, which is 90 s.
        w.reminder.observeIdle(150, now: shownAt.addingTimeInterval(240))
        #expect(w.reminder.settling?.panel.maxIdleSeconds == 90)
    }

    @Test func ticksMakeCompletedOrPartial() {
        var w = world()
        w.showReminder()
        w.tick(0); w.tick(1); w.tick(2)
        w.run(for: 200)
        #expect(w.last?.outcome == .completed)
        #expect(w.state.sittingSince == w.last?.settling.until)

        var p = world()
        p.showReminder()
        p.tick(1)
        p.run(for: 200)
        #expect(p.last?.outcome == .partial)
        #expect(p.last?.settling.panel.tickedItemIDs == ["back-bend"])
        #expect(p.state.sittingSince == p.last?.settling.until)
    }

    @Test func snoozeFromThePanelSettlesAtOnceWithNoIdleWatch() {
        var w = world()
        w.showReminder()
        w.tick(0)
        w.run(for: 10)
        w.snooze()
        #expect(w.reminder.phase == .idle)
        #expect(w.last?.outcome == .snoozed)
        #expect(w.last?.settling.until == w.now)
        #expect(w.closes == [.snoozed])
        #expect(w.state.sittingSince == t0.addingTimeInterval(-3600))
        #expect(w.state.today.ignored == 0)
        #expect(w.state.nagAfter == nil)
    }

    @Test func anOutcomeOtherThanIgnoredClearsAnEarlierNag() {
        var w = world()
        w.showReminder()
        w.notNow()
        w.run(for: 180)
        #expect(w.state.nagAfter != nil)
        w.run(for: 25 * 60)
        w.showReminder()
        w.tick(0)
        w.notNow()
        w.run(for: 180)
        #expect(w.last?.outcome == .partial)
        #expect(w.state.nagAfter == nil)
    }

    @Test func aRealBreakClearsNagAfter() {
        for input in [SittingTimer.Input.poll(idleSeconds: 300), .launch, .wake(sleptAt: t0.addingTimeInterval(-400)),
                      .sessionBecameActive(resignedAt: t0.addingTimeInterval(-400))] {
            var s = MickState.defaults(now: t0, calendar: utc)
            s.sittingSince = t0.addingTimeInterval(-3600)
            s.lastActiveAt = t0.addingTimeInterval(-400)
            s.nagAfter = t0.addingTimeInterval(600)
            #expect(SittingTimer.apply(input, config: config, now: t0, to: &s) != nil, "\(input)")
            #expect(s.nagAfter == nil, "\(input)")
        }
        // No break, no change.
        var s = MickState.defaults(now: t0, calendar: utc)
        s.nagAfter = t0.addingTimeInterval(600)
        SittingTimer.apply(.poll(idleSeconds: 299), config: config, now: t0, to: &s)
        #expect(s.nagAfter == t0.addingTimeInterval(600))
    }

    // MARK: - Spacing and the settle block

    @Test func ignoredComesBackAboutTwentyFiveMinutesLaterCompletedWaitsTheFullThreshold() {
        var w = world()
        w.showReminder()
        w.notNow()
        w.run(for: 180)
        let settled = w.last!.settling.until
        #expect(!w.armed)
        w.now = settled.addingTimeInterval(25 * 60 - 1)
        #expect(!w.armed)
        w.now = settled.addingTimeInterval(25 * 60)
        #expect(w.armed)

        var c = world()
        c.showReminder()
        c.tick(0); c.tick(1); c.tick(2)
        c.run(for: 200)
        let done = c.last!.settling.until
        c.now = done.addingTimeInterval(49 * 60)
        #expect(!c.armed)
        c.now = done.addingTimeInterval(50 * 60)
        #expect(c.armed)
    }

    @Test func ignoringNeverLowersSittingTimeAndRepeatedIgnoresStillReachGlaring() {
        var w = world(sittingMinutes: 50)
        var lastSitting = w.sittingMinutes
        var glaredAt: Double?
        for _ in 0..<4 {
            w.showReminder()
            w.run(for: 5)
            w.notNow()
            w.run(for: 180)
            #expect(w.last?.outcome == .ignored)
            #expect(w.sittingMinutes >= lastSitting)
            lastSitting = w.sittingMinutes
            // Sit until armed again, checking the displayed time only ever goes up.
            while !w.armed {
                w.now = w.now.addingTimeInterval(60)
                #expect(w.sittingMinutes >= lastSitting)
                lastSitting = w.sittingMinutes
            }
            if glaredAt == nil, SittingTimer.isGlaring(w.state, config: config, now: w.now) { glaredAt = w.sittingMinutes }
        }
        #expect(w.state.today.ignored == 4)
        #expect(w.sittingMinutes >= 100)
        #expect(glaredAt != nil)
        #expect(MenuBarIcon.current(hooks: .detected(lastEventAt: w.now), state: w.state, config: config, now: w.now) == .glaring)
    }

    @Test func aPromptWhileSettlingNeverSchedulesAnother() {
        var w = world()
        w.showReminder()
        w.event(.stop, "A")  // auto-dismissed, settling until shown + 3 min
        w.run(for: 60)
        w.event(.prompt, "B")
        w.event(.prompt, "A")
        #expect(w.effects.suffix(2) == [.notScheduled(sessionID: "B", .busy), .notScheduled(sessionID: "A", .busy)])
        #expect(w.reminder.settling != nil)
        w.run(for: 120)
        // Settled as Ignored: the nag keeps the next prompt from scheduling.
        #expect(w.last?.outcome == .ignored)
        w.event(.prompt, "C")
        #expect(w.effects.last == .notScheduled(sessionID: "C", .notArmed))
    }

    // MARK: - Midnight

    @Test func ignoredTodayResetsAtLocalMidnight() {
        var s = MickState.defaults(now: t0, calendar: utc)
        s.today.ignored = 3
        let lateEvening = utc.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 23, minute: 59, second: 59))!
        let midnight = utc.date(from: DateComponents(year: 2026, month: 9, day: 22))!
        #expect(!MickMemory.rollOver(&s, now: lateEvening, calendar: utc))
        #expect(s.today == MickState.Today(date: "2026-09-21", ignored: 3))
        #expect(MickMemory.ignoredToday(s, now: lateEvening, calendar: utc) == 3)
        #expect(MickMemory.ignoredToday(s, now: midnight, calendar: utc) == 0)
        #expect(MickMemory.rollOver(&s, now: midnight, calendar: utc))
        #expect(s.today == MickState.Today(date: "2026-09-22", ignored: 0))
    }

    @Test func midnightFollowsTheLocalTimeZone() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 2026-09-21 14:59:59 UTC is 23:59:59 in Tokyo; a second later is the next day there.
        let before = utc.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 14, minute: 59, second: 59))!
        var s = MickState(sittingSince: before, lastActiveAt: before, today: .init(date: "2026-09-21", ignored: 2))
        #expect(!MickMemory.rollOver(&s, now: before, calendar: tokyo))
        #expect(MickMemory.rollOver(&s, now: before.addingTimeInterval(1), calendar: tokyo))
        #expect(s.today == .init(date: "2026-09-22", ignored: 0))
    }

    @Test func anIgnoreAfterMidnightStartsTheNewDayAtOne() {
        var s = MickState.defaults(now: t0, calendar: utc)
        s.today = .init(date: "2026-09-20", ignored: 5)
        Settlement(settling()).apply(config: config, now: t0.addingTimeInterval(180), calendar: utc, to: &s)
        #expect(s.today == .init(date: "2026-09-21", ignored: 1))
    }

    @Test func aNonIgnoredSettleStillRollsTheDayOver() {
        var s = MickState.defaults(now: t0, calendar: utc)
        s.today = .init(date: "2026-09-20", ignored: 5)
        Settlement(settling(ticked: [0])).apply(config: config, now: t0.addingTimeInterval(180), calendar: utc, to: &s)
        #expect(s.today == .init(date: "2026-09-21", ignored: 0))
    }

    // MARK: - Reminder log line (§12.3)

    @Test func recordHasTheSpecFieldsOnOneLine() throws {
        var w = world(sittingMinutes: 54)
        w.showReminder()
        w.tick(0); w.tick(1)
        w.notNow()
        w.run(for: 200)
        let record = try #require(w.last?.record)
        #expect(record.sessionID == "A")
        #expect(record.cwd == "/tmp/p")
        #expect(record.sittingMinutes == 54)
        #expect(record.routine == ["stand", "back-bend", "shoulder-rolls"])
        #expect(record.ticked == ["stand", "back-bend"])
        #expect(record.outcome == .partial)
        #expect(!record.manual)
        #expect(record.settledAt == record.shownAt.addingTimeInterval(180))

        let line = try record.jsonLine()
        #expect(!line.contains("\n"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["shown_at", "settled_at", "session_id", "cwd", "sitting_minutes", "routine",
                                     "ticked", "max_idle_seconds", "outcome", "manual"])
        #expect(object["outcome"] as? String == "partial")
        #expect(object["cwd"] as? String == "/tmp/p")
        #expect(object["manual"] as? Bool == false)
        #expect(object["max_idle_seconds"] as? Int == record.maxIdleSeconds)
        #expect(MickDate.date(from: object["shown_at"] as? String ?? "") == record.shownAt)

        let decoded = try JSONDecoder.mick().decode(ReminderRecord.self, from: Data(line.utf8))
        #expect(decoded == record)
    }

    @Test func outcomeStringsMatchTheSpec() {
        #expect(Outcome.allCases.map(\.rawValue) == ["completed", "partial", "stood_up", "ignored", "snoozed"])
    }

    @Test func manualRecordHasANullSession() throws {
        let record = ReminderRecord(settling(session: nil), outcome: .ignored)
        #expect(record.manual)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(try record.jsonLine().utf8)) as? [String: Any])
        #expect(object["session_id"] is NSNull)
        #expect(object["manual"] as? Bool == true)
    }
}

private extension OutcomeTests.World {
    var closes: [Reminder.CloseReason] {
        effects.compactMap { if case .closed(_, let r) = $0 { r } else { nil } }
    }
}
