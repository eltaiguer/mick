import Foundation
import Synchronization
import Testing
@testable import MickIO
import MickCore

/// A clock and idle reading the test moves by hand.
final class FakeSystem: Sendable {
    private let nowStorage: Mutex<Date>
    private let idleStorage = Mutex<Double>(0)

    init(now: Date) { nowStorage = Mutex(now) }

    var now: Date {
        get { nowStorage.withLock { $0 } }
        set { nowStorage.withLock { $0 = newValue } }
    }
    var idle: Double {
        get { idleStorage.withLock { $0 } }
        set { idleStorage.withLock { $0 = newValue } }
    }
    func advance(_ seconds: TimeInterval) { nowStorage.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@MainActor
@Suite(.serialized) struct SittingEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func engine(_ temp: TempHome, _ sys: FakeSystem, log: MemoryLog = MemoryLog(), tunables: MickEngine.Tunables = .init()) -> MickEngine {
        MickEngine(home: temp.home, log: log, tunables: tunables, clock: { sys.now }, idleSeconds: { sys.idle })
    }

    private func saved(_ temp: TempHome) -> MickState {
        JSONFileStore.load(MickState.self, from: temp.home.state, defaults: .defaults(now: .distantPast), now: Date(), log: MemoryLog()).value
    }

    private func writeState(_ temp: TempHome, sittingSince: Date, lastActiveAt: Date) throws {
        var s = MickState.defaults(now: t0)
        s.sittingSince = sittingSince
        s.lastActiveAt = lastActiveAt
        try JSONFileStore.save(s, to: temp.home.state)
    }

    @Test func relaunchAfterTheBreakResetResetsSittingTime() throws {
        let temp = try TempHome()
        try writeState(temp, sittingSince: t0.addingTimeInterval(-3600), lastActiveAt: t0.addingTimeInterval(-600))
        let sys = FakeSystem(now: t0)
        let log = MemoryLog()
        let e = engine(temp, sys, log: log)
        defer { e.stop() }
        try e.start()
        #expect(e.state.sittingSince == t0)
        #expect(saved(temp).sittingSince == t0)
        #expect(log.messages.contains { $0.contains("sitting timer reset (away 600s before launch)") })
    }

    @Test func quickRelaunchKeepsSittingTimeAndItPersists() throws {
        let temp = try TempHome()
        let since = t0.addingTimeInterval(-3600)
        try writeState(temp, sittingSince: since, lastActiveAt: t0.addingTimeInterval(-120))
        let sys = FakeSystem(now: t0)
        let e = engine(temp, sys)
        try e.start()
        #expect(e.state.sittingSince == since)
        #expect(e.icon == .warning)  // hooks never seen; the sitting states need hooks
        e.stop()

        // Relaunch 1 minute later: still sitting since the same time, from state.json.
        sys.advance(60)
        let again = engine(temp, sys)
        defer { again.stop() }
        try again.start()
        #expect(again.state.sittingSince == since)
        #expect(again.sittingDetail == "Sitting 1h 1m · reminder armed")
    }

    @Test func startRecordsLastActiveAsNowMinusIdle() throws {
        let temp = try TempHome()
        let sys = FakeSystem(now: t0)
        sys.idle = 42
        let e = engine(temp, sys)
        defer { e.stop() }
        try e.start()
        #expect(e.state.lastActiveAt == t0.addingTimeInterval(-42))
        #expect(saved(temp).lastActiveAt == t0.addingTimeInterval(-42))
    }

    @Test func pollingThroughAFortyMinuteBreak() throws {
        let temp = try TempHome()
        let sys = FakeSystem(now: t0)
        let log = MemoryLog()
        let e = engine(temp, sys, log: log)
        defer { e.stop() }
        try e.start()
        // 30 minutes of work, then 40 minutes away, polled every 30 s.
        for _ in 0..<60 { sys.advance(30); sys.idle = 1; e.poll() }
        for i in 1...80 { sys.advance(30); sys.idle = Double(i * 30); e.poll() }
        sys.advance(30); sys.idle = 5; e.poll()
        #expect(SittingTimer.sittingSeconds(e.state, now: sys.now) <= 30)
        #expect(e.sittingDetail == "Sitting 0m · reminder at 50m")
        // Written atomically on each poll; the file matches memory.
        #expect(saved(temp).sittingSince == e.state.sittingSince)
        #expect(saved(temp).lastActiveAt == sys.now.addingTimeInterval(-5))
        // One log line for the whole break, not one per poll.
        #expect(log.messages.filter { $0.contains("sitting timer reset (idle") }.count == 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.home.url.path).filter { $0.hasPrefix(".") || $0.contains("tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func sleepingForTheBreakResetResetsToTheWakeTime() throws {
        let temp = try TempHome()
        let sys = FakeSystem(now: t0)
        let e = engine(temp, sys)
        defer { e.stop() }
        try e.start()
        sys.advance(40 * 60)
        e.willSleep()
        sys.advance(5 * 60)
        e.didWake()
        #expect(e.state.sittingSince == sys.now)
        #expect(saved(temp).sittingSince == sys.now)

        // A 4-minute nap doesn't count.
        sys.advance(20 * 60)
        e.willSleep()
        sys.advance(4 * 60)
        let before = e.state.sittingSince
        e.didWake()
        #expect(e.state.sittingSince == before)
    }

    @Test func switchingUsersAwayForTheBreakResetResets() throws {
        let temp = try TempHome()
        let sys = FakeSystem(now: t0)
        let e = engine(temp, sys)
        defer { e.stop() }
        try e.start()
        sys.advance(40 * 60)
        e.sessionDidResignActive()
        sys.advance(3 * 60)
        e.sessionDidBecomeActive()
        #expect(e.state.sittingSince == t0)
        e.sessionDidResignActive()
        sys.advance(6 * 60)
        e.sessionDidBecomeActive()
        #expect(e.state.sittingSince == sys.now)
    }

    @Test func iconFollowsSittingTimeOnceHooksAreDetected() async throws {
        let temp = try TempHome()
        let sys = FakeSystem(now: t0)
        let e = engine(temp, sys)
        defer { e.stop() }
        try e.start()
        try temp.append(line("prompt", t0.timeIntervalSince1970, "A"))
        e.tick()
        e.flushTailer()
        #expect(await eventually { e.hooks.everDetected })
        #expect(e.icon == .calm)
        sys.advance(50 * 60)
        #expect(e.icon == .armed)
        sys.advance(50 * 60)
        #expect(e.icon == .glaring)
    }

    @Test func thePollTimerRuns() async throws {
        let temp = try TempHome()
        let sys = FakeSystem(now: t0)
        var tunables = MickEngine.Tunables()
        tunables.pollInterval = 0.05
        let e = engine(temp, sys, tunables: tunables)
        defer { e.stop() }
        try e.start()
        sys.idle = 7
        sys.advance(100)
        #expect(await eventually { e.state.lastActiveAt == t0.addingTimeInterval(93) })
        e.stop()
        sys.advance(100)
        try await Task.sleep(for: .milliseconds(200))
        #expect(e.state.lastActiveAt == t0.addingTimeInterval(93))
    }
}
