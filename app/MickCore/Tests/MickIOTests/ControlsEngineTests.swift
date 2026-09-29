import Foundation
import Testing
@testable import MickIO
import MickCore

/// Snooze, pause, quiet hours and Stretch now through the engine: real tailer events,
/// `state.json`, `reminders.jsonl` and relaunches, all against a temporary MICK_HOME.
@MainActor
@Suite(.serialized) struct ControlsEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func home(now: Date, sittingMinutes: Double = 60, config: MickConfig = MickConfig()) throws -> TempHome {
        let temp = try TempHome()
        var s = MickState.defaults(now: now)
        s.sittingSince = now.addingTimeInterval(-sittingMinutes * 60)
        s.lastActiveAt = now
        s.lastEventAt = now.addingTimeInterval(-60)
        try JSONFileStore.save(s, to: temp.home.state)
        try JSONFileStore.save(config, to: temp.home.config)
        return temp
    }

    private func start(_ temp: TempHome, _ sys: FakeSystem, log: MemoryLog = MemoryLog()) throws -> MickEngine {
        let e = MickEngine(home: temp.home, log: log, clock: { sys.now }, idleSeconds: { sys.idle },
                           activity: ActivityAssertion(begin: { NSObject() }, end: { _ in }))
        try e.start()
        e.flushTailer()
        return e
    }

    private func send(_ temp: TempHome, _ e: MickEngine, _ kind: String, _ session: String, at t: Date) async throws {
        let before = e.state.sessions[session]?.lastEventAt
        try temp.append(line(kind, t.timeIntervalSince1970, session))
        e.flushTailer()
        let applied = await eventually { e.state.sessions[session]?.lastEventAt != before }
        #expect(applied, "\(kind) for \(session) not applied")
    }

    private func saved(_ temp: TempHome) -> MickState {
        JSONFileStore.load(MickState.self, from: temp.home.state, defaults: .defaults(now: .distantPast), now: Date(), log: MemoryLog()).value
    }

    private func records(_ temp: TempHome) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: temp.home.reminders.path) else { return [] }
        let text = try String(contentsOf: temp.home.reminders, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func follow(_ e: MickEngine, _ sys: FakeSystem, seconds: Int) {
        for _ in 0..<(seconds / 5) {
            sys.advance(5)
            e.poll()
            e.runReminderTimers()
        }
    }

    // MARK: - Snooze

    @Test func snoozeFromThePanelSettlesAsSnoozedWithNoPenalty() async throws {
        let temp = try home(now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }
        let sitting = e.state.sittingSince
        try await send(temp, e, "prompt", "A", at: sys.now)
        sys.advance(30)
        e.runReminderTimers()
        #expect(e.reminder.panel != nil)

        e.snooze(.oneHour)
        #expect(e.reminder.phase == .idle)
        #expect(e.lastSettlement?.outcome == .snoozed)
        #expect(e.state.snoozedUntil == sys.now.addingTimeInterval(3600))
        #expect(e.state.sittingSince == sitting)
        #expect(e.state.today.ignored == 0 && e.state.nagAfter == nil)
        #expect(e.icon == .snoozed)
        #expect(e.noticeLine == "Sixty minutes. I'll be here.")
        let r = try records(temp)
        #expect(r.count == 1)
        #expect(r.first?["outcome"] as? String == "snoozed")
        #expect(r.first?["manual"] as? Bool == false)
        #expect(saved(temp).snoozedUntil == e.state.snoozedUntil)

        // A prompt during the snooze schedules nothing.
        try await send(temp, e, "prompt", "B", at: sys.now)
        #expect(e.reminder.phase == .idle)
    }

    @Test func snoozeFromTheMenuDoesntTouchTheSittingTimerAndRunsOut() async throws {
        let temp = try home(now: t0)
        let sys = FakeSystem(now: t0)
        let log = MemoryLog()
        let e = try start(temp, sys, log: log)
        defer { e.stop() }
        let sitting = e.state.sittingSince
        e.snooze(.thirtyMinutes)
        #expect(e.state.snoozedUntil == t0.addingTimeInterval(1800))
        #expect(e.state.sittingSince == sitting)
        #expect(e.icon == .snoozed)
        #expect(e.noticeLine == "Thirty minutes. I'll be here.")
        #expect(e.lastSettlement == nil)

        // The notice is brief.
        sys.advance(StatusNotice.duration)
        #expect(e.noticeLine == nil)

        // It ends on its own: the next poll after it runs out clears it.
        sys.advance(1800)
        e.poll()
        #expect(e.state.snoozedUntil == nil)
        #expect(e.state.sittingSince == sitting)
        #expect(e.icon == .armed)
        #expect(log.messages.contains { $0.contains("snooze over") })
    }

    @Test func snoozeUntilTomorrowIsTheNextSixAM() throws {
        let temp = try home(now: t0)
        let sys = FakeSystem(now: t0)
        let e = try start(temp, sys)
        defer { e.stop() }
        e.snooze(.untilTomorrow)
        let until = try #require(e.state.snoozedUntil)
        #expect(until == SnoozeOption.untilTomorrow.until(from: t0))
        #expect(Calendar.current.component(.hour, from: until) == 6)
        #expect(until > t0 && until.timeIntervalSince(t0) <= 24 * 3600 + 3600)
    }

    // MARK: - Pause

    @Test func pausePersistsAcrossRelaunchAndNeverResetsSitting() async throws {
        let temp = try home(now: t0)
        let sys = FakeSystem(now: t0)
        let e = try start(temp, sys)
        let sitting = e.state.sittingSince
        e.pause()
        #expect(e.isPaused)
        #expect(e.icon == .paused)
        #expect(e.noticeLine == "Fine. Go soft.")
        #expect(e.state.sittingSince == sitting)
        try await send(temp, e, "prompt", "A", at: sys.now)
        #expect(e.reminder.phase == .idle)
        e.stop()

        // Relaunch a minute later: still paused, sitting time kept.
        sys.advance(60)
        let again = try start(temp, sys)
        defer { again.stop() }
        #expect(again.isPaused)
        #expect(again.icon == .paused)
        #expect(again.state.sittingSince == sitting)
        #expect(again.noticeLine == nil)  // in memory only

        again.resume()
        #expect(!again.isPaused)
        #expect(again.noticeLine == "About time.")
        #expect(again.state.sittingSince == sitting)
        #expect(!saved(temp).paused)
        #expect(again.icon == .armed)
    }

    @Test func resumeEndsASnoozeAndDoesNothingWhenNeither() throws {
        let temp = try home(now: t0)
        let sys = FakeSystem(now: t0)
        let e = try start(temp, sys)
        defer { e.stop() }
        e.resume()
        #expect(e.noticeLine == nil)
        e.snooze(.twoHours)
        e.resume()
        #expect(e.state.snoozedUntil == nil)
        #expect(e.noticeLine == "About time.")
    }

    @Test func pausingDuringTheShowDelayDropsTheCheck() async throws {
        let temp = try home(now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }
        try await send(temp, e, "prompt", "A", at: sys.now)
        #expect(e.reminder.check != nil)
        e.pause()
        sys.advance(30)
        e.runReminderTimers()
        #expect(e.reminder.phase == .idle)
        #expect(e.lastSettlement == nil)
    }

    // MARK: - Quiet hours

    @Test func quietHoursBlockTriggersAndShowThePausedIcon() async throws {
        // A window around the local time of t0, since the engine uses the current calendar.
        let cal = Calendar.current
        func hhmm(_ d: Date) -> String {
            String(format: "%02d:%02d", cal.component(.hour, from: d), cal.component(.minute, from: d))
        }
        let quiet = QuietHours(start: hhmm(t0.addingTimeInterval(-3600)), end: hhmm(t0.addingTimeInterval(3600)))
        let temp = try home(now: t0, config: MickConfig(quietHours: quiet))
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }
        #expect(e.icon == .paused)
        try await send(temp, e, "prompt", "A", at: sys.now)
        #expect(e.reminder.phase == .idle)
        #expect(!e.isPaused)  // quiet hours aren't a pause

        // After quiet hours end, the next prompt schedules.
        sys.advance(2 * 3600)
        #expect(e.icon == .glaring)
        try await send(temp, e, "prompt", "B", at: sys.now)
        #expect(e.reminder.check?.sessionID == "B")
    }

    // MARK: - Stretch now

    @Test func stretchNowShowsANormalRoutineThatAgentStopsDontClose() async throws {
        let temp = try home(now: t0, sittingMinutes: 120)  // glaring, but Stretch now is a normal routine
        let sys = FakeSystem(now: t0)
        let log = MemoryLog()
        let e = try start(temp, sys, log: log)
        defer { e.stop() }
        var shown: [Reminder.Panel] = []
        e.onReminder = { effects in
            for case .show(let p) in effects { shown.append(p) }
        }
        try await send(temp, e, "prompt", "A", at: sys.now)
        #expect(e.reminder.check != nil)
        #expect(!e.canStretchNow)
        #expect(!e.stretchNow())
        try await send(temp, e, "stop", "A", at: sys.now.addingTimeInterval(1))
        #expect(e.reminder.phase == .idle)
        #expect(e.canStretchNow)

        #expect(e.stretchNow())
        let panel = try #require(e.reminder.panel)
        #expect(shown.count == 1 && shown.first?.isManual == true)
        #expect(panel.sessionID == nil)
        #expect(panel.content.items.count == 3 && panel.content.items[0].id == "stand")
        let moves = panel.content.items.dropFirst().compactMap { e.moves?.move(id: $0.id) }
        #expect(moves.count == 2 && moves[0].area != moves[1].area)
        #expect(e.state.rotation.lastAreas == moves.map(\.area))
        #expect(saved(temp).rotation.lastAreas == moves.map(\.area))
        #expect(log.messages.contains { $0.contains("stretch now shown") })
        #expect(e.isHoldingActivity)
        #expect(!e.canStretchNow)

        // Agent events don't close it.
        sys.advance(2)
        try await send(temp, e, "prompt", "B", at: sys.now)
        try await send(temp, e, "stop", "B", at: sys.now.addingTimeInterval(0.5))
        try await send(temp, e, "end", "A", at: sys.now.addingTimeInterval(1))
        #expect(e.reminder.panel != nil)

        // Tick one; it closes 2 minutes after the last tick and settles as Partial.
        e.setReminderItem(0, ticked: true)
        let tickedAt = sys.now
        follow(e, sys, seconds: 115)
        #expect(e.reminder.panel != nil)
        follow(e, sys, seconds: 5)
        #expect(e.reminder.panel == nil)
        #expect(sys.now.timeIntervalSince(tickedAt) == 120)
        follow(e, sys, seconds: 60)
        #expect(e.reminder.phase == .idle)
        #expect(e.lastSettlement?.outcome == .partial)
        let r = try records(temp)
        #expect(r.count == 1)
        #expect(r.first?["manual"] as? Bool == true)
        #expect(r.first?["session_id"] is NSNull)
        #expect(r.first?["outcome"] as? String == "partial")
        #expect(e.state.sittingSince == e.lastSettlement?.settling.until)
    }

    @Test func untouchedStretchNowIgnoredLeavesMemoryAlone() throws {
        let temp = try home(now: t0)
        let sys = FakeSystem(now: t0)
        let e = try start(temp, sys)
        defer { e.stop() }
        let sitting = e.state.sittingSince
        #expect(e.stretchNow())
        follow(e, sys, seconds: 180)
        #expect(e.reminder.phase == .idle)
        #expect(e.lastSettlement?.outcome == .ignored)
        #expect(e.lastSettlement?.settling.reason == .untouched)
        #expect(e.state.sittingSince == sitting)
        #expect(e.state.nagAfter == nil)
        #expect(e.state.today.ignored == 0)
        #expect(try records(temp).first?["manual"] as? Bool == true)
    }

    @Test func stretchNowWorksWhilePausedOrSnoozed() throws {
        let temp = try home(now: t0, sittingMinutes: 10)
        let sys = FakeSystem(now: t0)
        let e = try start(temp, sys)
        defer { e.stop() }
        e.pause()
        e.snooze(.oneHour)
        #expect(e.canStretchNow)
        #expect(e.stretchNow())
        #expect(e.reminder.panel?.isManual == true)
    }
}
