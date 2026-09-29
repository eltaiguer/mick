import Foundation
import Synchronization
import Testing
@testable import MickIO
import MickCore

/// Counts begin/end calls of the App Nap activity.
@MainActor
final class FakeActivity {
    private(set) var begins = 0
    private(set) var ends = 0
    var held: Bool { begins > ends }
    lazy var assertion = ActivityAssertion(
        begin: { [unowned self] in self.begins += 1; return NSObject() },
        end: { [unowned self] _ in self.ends += 1 }
    )
}

/// The reminder wired through the engine: events from the real tailer, the one-shot
/// timer, the activity assertion (§6.3, §7, §9.2).
@MainActor
@Suite(.serialized) struct ReminderEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A home where you've been sitting for an hour and the hooks are known.
    private func armedHome(sittingMinutes: Double = 60, config: MickConfig = MickConfig(), now: Date) throws -> TempHome {
        let temp = try TempHome()
        var s = MickState.defaults(now: now)
        s.sittingSince = now.addingTimeInterval(-sittingMinutes * 60)
        s.lastActiveAt = now
        s.lastEventAt = now.addingTimeInterval(-60)
        try JSONFileStore.save(s, to: temp.home.state)
        try JSONFileStore.save(config, to: temp.home.config)
        return temp
    }

    private final class EffectLog {
        var effects: [Reminder.Effect] = []
        var shows: Int { effects.filter { if case .show = $0 { true } else { false } }.count }
        var closes: [Reminder.CloseReason] { effects.compactMap { if case .closed(_, let r) = $0 { r } else { nil } } }
    }

    private func start(_ temp: TempHome, _ sys: FakeSystem, activity: FakeActivity, log: MemoryLog = MemoryLog()) throws -> (MickEngine, EffectLog) {
        let e = MickEngine(home: temp.home, log: log, clock: { sys.now }, idleSeconds: { sys.idle }, activity: activity.assertion)
        let effects = EffectLog()
        e.onReminder = { effects.effects += $0 }
        try e.start()
        e.flushTailer()
        return (e, effects)
    }

    private func send(_ temp: TempHome, _ e: MickEngine, _ kind: String, _ session: String, at t: Date) async throws {
        let before = e.state.sessions[session]?.lastEventAt
        try temp.append(line(kind, t.timeIntervalSince1970, session))
        e.flushTailer()
        let applied = await eventually { e.state.sessions[session]?.lastEventAt != before }
        #expect(applied, "\(kind) for \(session) not applied")
    }

    @Test func promptShowsAfterTheDelayAndAStopClosesIt() async throws {
        let temp = try armedHome(now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let activity = FakeActivity()
        let log = MemoryLog()
        let (e, fx) = try start(temp, sys, activity: activity, log: log)
        defer { e.stop() }
        #expect(!activity.held)  // nothing running, nothing scheduled

        try await send(temp, e, "prompt", "A", at: t0)
        #expect(e.reminder.check?.sessionID == "A")
        #expect(activity.held)

        sys.advance(29)
        e.runReminderTimers()
        #expect(fx.shows == 0)
        sys.advance(1)
        e.runReminderTimers()
        #expect(fx.shows == 1)
        #expect(e.reminder.panel?.sessionID == "A")

        sys.advance(20)
        try await send(temp, e, "stop", "A", at: sys.now)
        #expect(fx.closes == [.agentStopped])
        // Settling until 3 minutes after it was shown: still holding the activity.
        #expect(e.reminder.settling != nil)
        #expect(activity.held)
        sys.advance(160)
        e.runReminderTimers()
        #expect(e.reminder.phase == .idle)
        #expect(!activity.held)
        #expect(activity.begins == 1 && activity.ends == 1)
        #expect(log.messages.contains { $0.contains("reminder shown for session A") })
        #expect(log.messages.contains { $0.contains("reminder closed (agentStopped)") })
    }

    @Test func runShorterThanTheDelayNeverShows() async throws {
        let temp = try armedHome(now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let activity = FakeActivity()
        let (e, fx) = try start(temp, sys, activity: activity)
        defer { e.stop() }
        try await send(temp, e, "prompt", "A", at: t0)
        sys.advance(12)
        try await send(temp, e, "stop", "A", at: sys.now)
        #expect(e.reminder.phase == .idle)
        for _ in 0..<60 { sys.advance(1); e.runReminderTimers() }
        #expect(fx.shows == 0)
        #expect(!activity.held)
    }

    @Test func backlogPromptAtLaunchNeverTriggers() async throws {
        let temp = try armedHome(now: t0)
        try temp.append(line("prompt", t0.addingTimeInterval(-5).timeIntervalSince1970, "A"))
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let activity = FakeActivity()
        let (e, fx) = try start(temp, sys, activity: activity)
        defer { e.stop() }
        #expect(await eventually { e.state.sessions["A"]?.running == true })
        #expect(e.reminder.phase == .idle)
        // A running session still holds the activity.
        #expect(activity.held)
        for _ in 0..<60 { sys.advance(1); e.runReminderTimers() }
        #expect(fx.shows == 0)
    }

    @Test func handOffAndOneReminderAcrossThreeSessions() async throws {
        let temp = try armedHome(now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let activity = FakeActivity()
        let (e, fx) = try start(temp, sys, activity: activity)
        defer { e.stop() }
        try await send(temp, e, "prompt", "A", at: t0)
        sys.advance(2); try await send(temp, e, "prompt", "B", at: sys.now)
        sys.advance(2); try await send(temp, e, "prompt", "C", at: sys.now)
        sys.advance(2); try await send(temp, e, "wait", "A", at: sys.now)
        #expect(e.reminder.check?.sessionID == "C")
        #expect(e.reminder.check?.fireAt == t0.addingTimeInterval(34))
        for _ in 0..<40 { sys.advance(1); e.runReminderTimers() }
        #expect(fx.shows == 1)
        #expect(e.reminder.panel?.sessionID == "C")
        try await send(temp, e, "prompt", "A", at: sys.now)
        try await send(temp, e, "prompt", "B", at: sys.now.addingTimeInterval(0.01))
        for _ in 0..<60 { sys.advance(1); e.runReminderTimers() }
        #expect(fx.shows == 1)
    }

    @Test func ticksKeepThePanelThroughAStopAndAllTickedCloses() async throws {
        let temp = try armedHome(now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let activity = FakeActivity()
        let (e, fx) = try start(temp, sys, activity: activity)
        defer { e.stop() }
        try await send(temp, e, "prompt", "A", at: t0)
        sys.advance(30); e.runReminderTimers()
        #expect(e.reminder.panel != nil)
        e.setReminderItem(0, ticked: true)
        sys.advance(1)
        try await send(temp, e, "stop", "A", at: sys.now)
        #expect(e.reminder.panel != nil)
        e.setReminderItem(1, ticked: true)
        e.setReminderItem(2, ticked: true)
        #expect(fx.effects.contains { if case .allTicked = $0 { true } else { false } })
        sys.advance(3); e.runReminderTimers()
        #expect(fx.closes == [.done])
    }

    /// The real one-shot timer and the real clock: a 1 s show delay fires on its own,
    /// and a stop closes the untouched panel well within 2 s.
    @Test func realTimerShowsAndAStopClosesWithinTwoSeconds() async throws {
        let now = Date()
        let temp = try armedHome(config: MickConfig(showDelaySeconds: 1), now: now)
        let activity = FakeActivity()
        let e = MickEngine(home: temp.home, log: MemoryLog(), idleSeconds: { 10 }, activity: activity.assertion)
        defer { e.stop() }
        try e.start()
        e.flushTailer()

        try temp.append(line("prompt", Date().timeIntervalSince1970, "R"))
        #expect(await eventually(timeout: .seconds(4)) { e.reminder.panel != nil }, "panel never shown")
        #expect(activity.held)

        let clock = ContinuousClock()
        let started = clock.now
        try temp.append(line("stop", Date().timeIntervalSince1970, "R"))
        let closed = await eventually(timeout: .seconds(2)) { e.reminder.settling != nil }
        #expect(closed, "not closed within 2 s")
        #expect(clock.now - started < .seconds(2))
    }

    @Test func stopReleasesTheActivity() throws {
        let temp = try armedHome(now: t0)
        let sys = FakeSystem(now: t0)
        let activity = FakeActivity()
        let (e, _) = try start(temp, sys, activity: activity)
        e.stop()
        #expect(!activity.held)
    }

    @Test func realActivityAssertionUsesTheSpecOptions() {
        #expect(ActivityAssertion.options == .userInitiatedAllowingIdleSystemSleep)
        #expect(!ActivityAssertion.options.contains(.latencyCritical))
        #expect(!ActivityAssertion.options.contains(.idleSystemSleepDisabled))
        let real = ActivityAssertion()
        #expect(real.hold(true))
        #expect(real.isHeld)
        #expect(!real.hold(true))
        #expect(real.hold(false))
        #expect(!real.isHeld)
    }
}
