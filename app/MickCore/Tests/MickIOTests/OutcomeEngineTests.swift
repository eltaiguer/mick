import Foundation
import Testing
@testable import MickIO
import MickCore

/// Outcomes through the engine (§8, §12.3): real tailer events, the idle poll, the
/// outcome landing in `state.json`, and one line per settled reminder in
/// `reminders.jsonl`.
@MainActor
@Suite(.serialized) struct OutcomeEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func armedHome(now: Date, today: MickState.Today? = nil) throws -> TempHome {
        let temp = try TempHome()
        var s = MickState.defaults(now: now)
        s.sittingSince = now.addingTimeInterval(-3600)
        s.lastActiveAt = now
        s.lastEventAt = now.addingTimeInterval(-60)
        if let today { s.today = today }
        try JSONFileStore.save(s, to: temp.home.state)
        try JSONFileStore.save(MickConfig(), to: temp.home.config)
        return temp
    }

    private func start(_ temp: TempHome, _ sys: FakeSystem, log: MemoryLog = MemoryLog()) throws -> MickEngine {
        let e = MickEngine(home: temp.home, log: log, clock: { sys.now }, idleSeconds: { sys.idle }, activity: ActivityAssertion(begin: { NSObject() }, end: { _ in }))
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

    /// Prompt, then the show delay: the panel is up.
    private func show(_ temp: TempHome, _ e: MickEngine, _ sys: FakeSystem, session: String = "A") async throws {
        try await send(temp, e, "prompt", session, at: sys.now)
        sys.advance(30)
        e.runReminderTimers()
        #expect(e.reminder.panel != nil)
    }

    /// Advances in 5-second polls, as the follow-up poll does.
    private func follow(_ e: MickEngine, _ sys: FakeSystem, seconds: Int, idleGrows: Bool = false) {
        for _ in 0..<(seconds / 5) {
            sys.advance(5)
            if idleGrows { sys.idle += 5 }
            e.poll()
            e.runReminderTimers()
        }
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

    @Test func anAutoDismissedReminderSettlesAsIgnoredSavesAndLogsOneLine() async throws {
        let temp = try armedHome(now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let log = MemoryLog()
        let e = try start(temp, sys, log: log)
        defer { e.stop() }
        var settled: [Settlement] = []
        e.onSettled = { settled.append($0) }

        try await show(temp, e, sys)
        let shownAt = sys.now
        sys.advance(20)
        try await send(temp, e, "stop", "A", at: sys.now)
        #expect(e.reminder.settling != nil)
        #expect(try records(temp).isEmpty)

        // A prompt a minute after the auto-dismiss never schedules another reminder.
        sys.advance(60)
        try await send(temp, e, "prompt", "B", at: sys.now)
        #expect(e.reminder.check == nil)
        #expect(e.reminder.settling != nil)

        follow(e, sys, seconds: 100)
        #expect(e.reminder.phase == .idle)
        #expect(settled.map(\.outcome) == [.ignored])

        let settledAt = shownAt.addingTimeInterval(180)
        let state = saved(temp)
        #expect(state.nagAfter.map(MickDate.micros) == MickDate.micros(settledAt.addingTimeInterval(25 * 60)))
        #expect(state.today.ignored == 1)
        #expect(MickDate.micros(state.sittingSince) == MickDate.micros(t0.addingTimeInterval(-3600)))

        let lines = try records(temp)
        #expect(lines.count == 1)
        let r = try #require(lines.first)
        #expect(r["outcome"] as? String == "ignored")
        #expect(r["session_id"] as? String == "A")
        #expect(r["cwd"] as? String == "/tmp/project")
        #expect(r["sitting_minutes"] as? Int == 60)
        #expect(r["routine"] as? [String] == ["stand", "back-bend", "shoulder-rolls"])
        #expect(r["ticked"] as? [String] == [])
        #expect(r["max_idle_seconds"] as? Int == 10)
        #expect(r["manual"] as? Bool == false)
        #expect((r["shown_at"] as? String).flatMap(MickDate.date).map(MickDate.micros) == MickDate.micros(shownAt))
        #expect((r["settled_at"] as? String).flatMap(MickDate.date).map(MickDate.micros) == MickDate.micros(settledAt))
        let attributes = try FileManager.default.attributesOfItem(atPath: temp.home.reminders.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(log.messages.contains { $0.contains("reminder settled (ignored") })

        // The nag holds Mick back until it passes, then he's armed again.
        sys.now = settledAt.addingTimeInterval(25 * 60 - 5)
        #expect(e.icon == .calm)
        sys.now = settledAt.addingTimeInterval(25 * 60)
        #expect(e.icon == .armed)
    }

    @Test func standingUpWithoutTickingCountsAsStoodUp() async throws {
        let temp = try armedHome(now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }
        try await show(temp, e, sys)
        #expect(e.currentPollInterval == 5)
        e.dismissReminder()  // "Not now", then walks away
        #expect(e.currentPollInterval == 5)  // still watching idle until it settles
        sys.idle = 0
        follow(e, sys, seconds: 180, idleGrows: true)
        #expect(e.reminder.phase == .idle)
        #expect(e.currentPollInterval == 30)
        let settlement = try #require(e.lastSettlement)
        #expect(settlement.outcome == .stoodUp)
        let state = saved(temp)
        #expect(MickDate.micros(state.sittingSince) == MickDate.micros(settlement.settling.until))
        #expect(state.nagAfter == nil)
        #expect(state.today.ignored == 0)
        #expect(try records(temp).first?["outcome"] as? String == "stood_up")
    }

    @Test func ticksSettleAsPartialAndCompleted() async throws {
        let temp = try armedHome(now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }

        try await show(temp, e, sys)
        e.setReminderItem(0, ticked: true)
        e.dismissReminder()
        follow(e, sys, seconds: 180)
        #expect(e.lastSettlement?.outcome == .partial)
        #expect(e.icon == .calm)

        // Sit the full threshold again, then complete one.
        sys.advance(50 * 60)
        sys.idle = 10
        try await show(temp, e, sys, session: "B")
        e.setReminderItem(0, ticked: true)
        e.setReminderItem(1, ticked: true)
        e.setReminderItem(2, ticked: true)
        follow(e, sys, seconds: 180)
        #expect(e.lastSettlement?.outcome == .completed)

        let lines = try records(temp)
        #expect(lines.map { $0["outcome"] as? String } == ["partial", "completed"])
        #expect(lines.map { $0["ticked"] as? [String] } == [["stand"], ["stand", "back-bend", "shoulder-rolls"]])
        #expect(lines.map { $0["session_id"] as? String } == ["A", "B"])
    }

    @Test func snoozeFromThePanelSettlesAtOnceWithNoPenalty() async throws {
        let temp = try armedHome(now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }
        try await show(temp, e, sys)
        let until = sys.now.addingTimeInterval(30 * 60)
        e.snoozeReminder(until: until)
        #expect(e.reminder.phase == .idle)
        #expect(e.lastSettlement?.outcome == .snoozed)
        #expect(e.currentPollInterval == 30)
        let state = saved(temp)
        #expect(state.snoozedUntil.map(MickDate.micros) == MickDate.micros(until))
        #expect(state.today.ignored == 0)
        #expect(state.nagAfter == nil)
        #expect(MickDate.micros(state.sittingSince) == MickDate.micros(t0.addingTimeInterval(-3600)))
        #expect(try records(temp).map { $0["outcome"] as? String } == ["snoozed"])
    }

    @Test func aBreakAfterAnIgnoreClearsTheNag() async throws {
        let temp = try armedHome(now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }
        try await show(temp, e, sys)
        e.dismissReminder()
        follow(e, sys, seconds: 180)
        #expect(e.state.nagAfter != nil)
        sys.advance(60)
        sys.idle = 300
        e.poll()
        #expect(e.state.nagAfter == nil)
        #expect(saved(temp).nagAfter == nil)
    }

    @Test func midnightRollsTheCountOverOnLaunchAndOnPolls() throws {
        // Yesterday's count is wiped on launch.
        let temp = try armedHome(now: t0, today: .init(date: "2000-01-01", ignored: 3))
        let sys = FakeSystem(now: t0)
        let log = MemoryLog()
        let e = try start(temp, sys, log: log)
        #expect(e.state.today == .init(date: MickDate.localDay(t0), ignored: 0))
        #expect(saved(temp).today.ignored == 0)
        #expect(log.messages.contains { $0.contains("memory of today reset") })
        e.stop()

        // A running app rolls over on the first poll after local midnight.
        let temp2 = try armedHome(now: t0, today: .init(date: MickDate.localDay(t0), ignored: 2))
        let sys2 = FakeSystem(now: t0)
        let e2 = try start(temp2, sys2)
        defer { e2.stop() }
        #expect(e2.state.today.ignored == 2)
        let midnight = Calendar.current.startOfDay(for: t0).addingTimeInterval(24 * 3600)
        sys2.now = midnight.addingTimeInterval(-1)
        e2.poll()
        #expect(e2.state.today.ignored == 2)
        sys2.now = midnight
        e2.poll()
        #expect(e2.state.today == .init(date: MickDate.localDay(midnight), ignored: 0))
        #expect(saved(temp2).today.ignored == 0)
    }

    @Test func ignoredTodayIsNeverShownAsANumber() async throws {
        let temp = try armedHome(now: t0, today: .init(date: MickDate.localDay(t0), ignored: 7))
        let sys = FakeSystem(now: t0)
        let e = try start(temp, sys)
        defer { e.stop() }
        // The only text the dropdown takes from the engine is the detail line.
        #expect(!e.sittingDetail.contains("7"))
    }
}
