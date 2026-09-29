import Foundation
import Testing
@testable import MickIO
import MickCore

/// Simulation mode (SPEC §16, issue #12): every scripted scenario replayed through the
/// real engine and tailer against a temporary home, with a fake clock, so the whole
/// timeline (including the 3-minute untouched close) runs in moments.
@MainActor
@Suite(.serialized) struct SimulationTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    final class Played {
        let run: SimulationRun
        let engine: MickEngine
        let root: URL
        let log: MemoryLog
        let activity: FakeActivity
        init(run: SimulationRun, engine: MickEngine, root: URL, log: MemoryLog, activity: FakeActivity) {
            self.activity = activity
            self.run = run
            self.engine = engine
            self.root = root
            self.log = log
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// Plays `scenario` in quarter-second steps of a fake clock. `idle` is the system
    /// idle reading throughout (10 s: not typing).
    private func play(_ scenario: SimulationScenario, idle: Double = 10) async throws -> Played {
        let root = try Simulation.makeRoot()
        let home = MickHome(url: root.appendingPathComponent("run", isDirectory: true))
        try Simulation.prepare(home, now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = idle
        let log = MemoryLog()
        let activity = FakeActivity()
        let engine = MickEngine(home: home, log: log, clock: { sys.now }, idleSeconds: { sys.idle }, activity: activity.assertion)
        try engine.start()
        engine.flushTailer()
        let run = SimulationRun(scenario: scenario, engine: engine, startedAt: t0)
        var tick = 0
        while sys.now <= run.endsAt {
            engine.runReminderTimers()
            let before = run.results.count
            if try run.performDueSteps(now: sys.now) > run.results.count - before {
                // An event was written: let the tailer deliver it before time moves on.
                engine.flushTailer()
                let size = (try? FileManager.default.attributesOfItem(atPath: home.events.path)[.size] as? UInt64) ?? 0
                let applied = await eventually { engine.state.eventsOffset == size }
                #expect(applied, "event not applied at +\(sys.now.timeIntervalSince(t0))s")
            }
            tick += 1
            sys.now = t0.addingTimeInterval(Double(tick) / 4)
        }
        engine.stop()
        #expect(run.isFinished)
        return Played(run: run, engine: engine, root: root, log: log, activity: activity)
    }

    private func expectPasses(_ id: SimulationScenario.ID) async throws -> Played {
        let played = try await play(.named(id))
        for failure in played.run.failures {
            Issue.record("\(id.rawValue) +\(failure.at)s: expected \(failure.expectation), got \(failure.actual)")
        }
        #expect(!played.run.results.isEmpty)
        return played
    }

    // MARK: - The seven scenarios

    @Test func normalRun() async throws {
        let p = try await expectPasses(.normalRun)
        #expect(p.run.shows == 1)
        #expect(p.log.messages.contains { $0.contains("reminder shown for session sim-a") })
    }

    @Test func shortRunShowsNothing() async throws {
        let p = try await expectPasses(.shortRun)
        #expect(p.run.shows == 0)
        #expect(!p.log.messages.contains { $0.contains("reminder shown") })
    }

    @Test func escInterruptClosesAfterThreeMinutesUntouched() async throws {
        let p = try await expectPasses(.escInterrupt)
        #expect(p.run.lastClose == .untouched)
        #expect(p.engine.state.sessions["sim-a"]?.running == true)  // Esc fires no hook
    }

    @Test func permissionPauseClosesThePanel() async throws {
        let p = try await expectPasses(.permissionPause)
        #expect(p.run.lastClose == .agentStopped)
    }

    @Test func threeConcurrentSessionsShowOneReminder() async throws {
        let p = try await expectPasses(.threeSessions)
        #expect(p.run.shows == 1)
        #expect(p.log.messages.filter { $0.contains("reminder check scheduled") }.count == 1)
    }

    @Test func earlyStopHandsTheCheckToTheRunningSession() async throws {
        let p = try await expectPasses(.handOff)
        #expect(p.log.messages.contains { $0.contains("reminder check scheduled for session sim-b") && $0.contains("handed off from sim-a") })
        #expect(p.log.messages.contains { $0.contains("reminder shown for session sim-b") })
    }

    @Test func stopBeforePromptLeavesTheSessionNotRunning() async throws {
        let p = try await expectPasses(.outOfOrder)
        #expect(p.engine.state.sessions["sim-a"]?.running == false)
        #expect(p.run.shows == 0)
    }

    // MARK: - The checker isn't vacuous

    @Test func typingThroughoutFailsTheShowExpectations() async throws {
        // Idle 0 means you're typing the whole time: the show waits, then gives up.
        let p = try await play(.named(.normalRun), idle: 0)
        #expect(!p.run.passed)
        #expect(p.run.failures.contains { $0.expectation == .visible(session: "sim-a") })
        #expect(p.run.shows == 0)
    }

    // MARK: - Home and events

    @Test func prepareWritesSimulationSettingsIntoATemporaryHome() throws {
        let root = try Simulation.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(root.path.hasPrefix(Simulation.resolved(Simulation.temporaryDirectory)) || root.path.hasPrefix(Simulation.temporaryDirectory.standardizedFileURL.path))
        let home = MickHome(url: root.appendingPathComponent("run"))
        try Simulation.prepare(home, now: t0)
        let mode = try FileManager.default.attributesOfItem(atPath: home.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        let config = JSONFileStore.load(MickConfig.self, from: home.config, defaults: .defaults, now: t0, log: MemoryLog()).value
        #expect(config.sitThresholdMinutes == 1 && config.breakResetMinutes == 1 && config.showDelaySeconds == 5)
        #expect(config.validated().problems.isEmpty)
        let state = JSONFileStore.load(MickState.self, from: home.state, defaults: .defaults(now: t0), now: t0, log: MemoryLog()).value
        #expect(SittingTimer.isArmed(state, config: config, now: t0))
        #expect(HooksStatus.evaluate(lastEventAt: state.lastEventAt, now: t0).everDetected)
    }

    @Test func refusesTheRealHomeAndNonTemporaryPaths() throws {
        let real = MickHome.resolve(environment: [:])
        #expect(throws: Simulation.SetupError.self) { try Simulation.checkTemporary(real) }
        #expect(throws: Simulation.SetupError.self) { try Simulation.prepare(real, now: t0) }
        let inside = MickHome(url: real.url.appendingPathComponent("sim"))
        #expect(throws: Simulation.SetupError.self) { try Simulation.checkTemporary(inside) }
        let elsewhere = MickHome(url: URL(fileURLWithPath: "/Users/Shared/mick-sim"))
        #expect(throws: Simulation.SetupError.self) { try Simulation.checkTemporary(elsewhere) }
        // A temp dir whose own path is under the "real" home is refused too.
        let fakeReal = MickHome(url: Simulation.temporaryDirectory.appendingPathComponent("pretend-real"))
        let under = MickHome(url: fakeReal.url.appendingPathComponent("x"))
        #expect(throws: Simulation.SetupError.self) { try Simulation.checkTemporary(under, realHome: fakeReal) }
        try Simulation.checkTemporary(MickHome(url: Simulation.temporaryDirectory.appendingPathComponent("mick-simulate-ok/run")))
    }

    @Test func eventLinesParseAsHookEvents() throws {
        let line = Simulation.eventLine(.wait, session: "sim-b", time: t0.addingTimeInterval(1.25))
        #expect(line.hasSuffix("\n") && line.filter { $0 == "\n" }.count == 1)
        let event = try EventParser.parse(line.dropLast()).get()
        #expect(event == MickEvent(kind: .wait, time: t0.timeIntervalSince1970 + 1.25, sessionID: "sim-b", cwd: SimulationScenario.cwd))
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        #expect(Set(object.keys) == ["e", "t", "s", "c", "n"])
    }

    @Test func appendCreatesTheEventsFileWithMode0600() throws {
        let root = try Simulation.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("events.jsonl")
        try Simulation.append("a\n", to: url)
        try Simulation.append("b\n", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "a\nb\n")
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }
}
