import Foundation
import Testing
@testable import MickIO
import MickCore

@MainActor
@Suite(.serialized) struct MickEngineTests {
    private func engine(_ temp: TempHome, log: MemoryLog = MemoryLog(), tunables: MickEngine.Tunables = .init()) -> MickEngine {
        MickEngine(home: temp.home, log: log, tunables: tunables, idleSeconds: { 0 })
    }

    @Test func firstLaunchCreatesHomeAndWritesDefaults() throws {
        let temp = try TempHome(create: false)
        let e = engine(temp)
        defer { e.stop() }
        try e.start()
        #expect(e.createdHome)
        let mode = try FileManager.default.attributesOfItem(atPath: temp.home.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(e.config == .defaults)
        #expect(e.configOutcome == .missing)
        #expect(e.stateOutcome == .missing)
        #expect(FileManager.default.fileExists(atPath: temp.home.config.path))
        #expect(FileManager.default.fileExists(atPath: temp.home.state.path))
        #expect(e.hooks == .notDetected)
        #expect(MenuBarIcon.current(hooks: e.hooks) == .warning)
    }

    @Test func corruptedStateAndConfigAreMovedAsideAndLogged() throws {
        let temp = try TempHome()
        try Data("{{{".utf8).write(to: temp.home.config)
        try Data(#"{"sitting_since": 12}"#.utf8).write(to: temp.home.state)
        let log = MemoryLog()
        let e = engine(temp, log: log)
        defer { e.stop() }
        try e.start()
        #expect(!e.createdHome)
        guard case .corrupt(let movedConfig?) = e.configOutcome, case .corrupt(let movedState?) = e.stateOutcome else {
            Issue.record("expected both corrupt: \(e.configOutcome) \(e.stateOutcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: movedConfig.path))
        #expect(FileManager.default.fileExists(atPath: movedState.path))
        #expect(e.config == .defaults)
        // Replaced with defaults on disk.
        let (config, outcome) = JSONFileStore.load(MickConfig.self, from: temp.home.config, defaults: .defaults, now: Date(), log: MemoryLog())
        #expect(outcome == .loaded)
        #expect(config == .defaults)
        #expect(log.messages.contains { $0.contains("config.json corrupted") })
        #expect(log.messages.contains { $0.contains("state.json corrupted") })
    }

    @Test func outOfRangeConfigValuesAreLoggedAndDefaulted() throws {
        let temp = try TempHome()
        try Data(#"{"sit_threshold_minutes": 0, "sound": true}"#.utf8).write(to: temp.home.config)
        let log = MemoryLog()
        let e = engine(temp, log: log)
        defer { e.stop() }
        try e.start()
        #expect(e.configOutcome == .loaded)
        #expect(e.config.sitThresholdMinutes == 50)
        #expect(e.config.sound)
        #expect(log.messages.contains { $0.contains("sit_threshold_minutes 0 is out of range") })
    }

    @Test func backlogUpdatesBookkeepingButIsReportedAsBacklog() async throws {
        let temp = try TempHome()
        let now = Date().timeIntervalSince1970
        try temp.append(
            line("prompt", now - 3 * 3600, "ancient")   // too old for bookkeeping
            + line("prompt", now - 60, "recent")
            + "not json at all\n"
            + line("stop", now - 30, "stopped")
        )
        let log = MemoryLog()
        let e = engine(temp, log: log)
        var seen: [(EventOrigin, [IntakeRecord])] = []
        e.onRecords = { records, origin in seen.append((origin, records)) }
        defer { e.stop() }
        try e.start()
        #expect(await eventually { e.state.eventsOffset == temp.size() })
        #expect(e.state.sessions["ancient"] == nil)
        #expect(e.state.sessions["recent"]?.running == true)
        #expect(e.state.sessions["stopped"]?.running == false)
        #expect(e.hooks.everDetected)
        #expect(seen.allSatisfy { $0.0 == .backlog })
        // Nothing in the backlog may trigger.
        let triggers = seen.flatMap(\.1).filter {
            if case .applied(_, true)? = $0.disposition { return true } else { return false }
        }
        #expect(triggers.isEmpty)
        #expect(log.messages.contains { $0.contains("skipped malformed event line") && $0.contains("not json at all") })
    }

    @Test func liveEventsAreAppliedAndPersisted() async throws {
        let temp = try TempHome()
        let e = engine(temp)
        var liveTriggers = 0
        e.onRecords = { records, origin in
            guard origin == .live else { return }
            liveTriggers += records.filter { if case .applied(_, true)? = $0.disposition { true } else { false } }.count
        }
        defer { e.stop() }
        try e.start()
        let now = Date().timeIntervalSince1970
        try temp.append(line("stop", now + 1) + line("prompt", now))  // out of order
        #expect(await eventually { e.state.eventsOffset == temp.size() })
        #expect(e.state.sessions["A"]?.running == false)
        #expect(liveTriggers == 0)

        try temp.append(line("prompt", now + 2))
        #expect(await eventually { e.state.sessions["A"]?.running == true })
        #expect(liveTriggers == 1)

        // Saved: a relaunch picks up where it left off.
        let saved = JSONFileStore.load(MickState.self, from: temp.home.state, defaults: .defaults(now: Date()), now: Date(), log: MemoryLog()).value
        #expect(saved.eventsOffset == temp.size())
        #expect(saved.sessions["A"]?.running == true)
    }

    @Test func relaunchContinuesFromTheSavedOffset() async throws {
        let temp = try TempHome()
        let now = Date().timeIntervalSince1970
        do {
            let e = engine(temp)
            try e.start()
            try temp.append(line("prompt", now))
            #expect(await eventually { e.state.eventsOffset == temp.size() })
            e.stop()
        }
        try temp.append(line("stop", now + 1))
        let e = engine(temp)
        var backlogLines = 0
        e.onRecords = { records, _ in backlogLines += records.count }
        defer { e.stop() }
        try e.start()
        #expect(await eventually { e.state.eventsOffset == temp.size() })
        #expect(backlogLines == 1)
        #expect(e.state.sessions["A"]?.running == false)
    }

    @Test func tickPrunesAndReevaluates() async throws {
        let temp = try TempHome()
        var state = MickState.defaults(now: Date())
        state.lastEventAt = Date().addingTimeInterval(-8 * 86400)
        state.sessions["idle"] = .init(running: true, runStartedAt: Date().addingTimeInterval(-3 * 3600), lastEventAt: Date().addingTimeInterval(-3 * 3600))
        try JSONFileStore.save(state, to: temp.home.state)
        let e = engine(temp)
        defer { e.stop() }
        try e.start()
        #expect(e.state.sessions.isEmpty)  // pruned at launch
        if case .stale = e.hooks {} else { Issue.record("expected stale, got \(e.hooks)") }
        #expect(MenuBarIcon.current(hooks: e.hooks) == .warning)

        try temp.append(line("prompt", Date().timeIntervalSince1970))
        #expect(await eventually { !e.hooks.showsWarning })
    }

    /// Acceptance: onboarding flips within 2 s of the first real hook event. This runs
    /// the plugin's real hook script against the temporary home.
    @Test func realHookEventIsDetectedWithinTwoSeconds() async throws {
        let temp = try TempHome()
        let e = engine(temp)
        defer { e.stop() }
        try e.start()
        e.flushTailer()
        #expect(e.hooks == .notDetected)

        let hook = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plugin/hooks/mick-event.sh")
        #expect(FileManager.default.isExecutableFile(atPath: hook.path))

        let process = Process()
        process.executableURL = hook
        process.arguments = ["prompt"]
        process.environment = ["MICK_HOME": temp.home.url.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        process.standardInput = stdin
        let clock = ContinuousClock()
        let started = clock.now
        try process.run()
        stdin.fileHandleForWriting.write(Data(#"{"session_id":"real-1","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit","prompt":"SECRET"}"#.utf8))
        try stdin.fileHandleForWriting.close()

        let flipped = await eventually(timeout: .seconds(2)) { e.hooks.everDetected }
        let elapsed = clock.now - started
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(flipped, "hooks not detected within 2 s")
        #expect(elapsed < .seconds(2))
        #expect(!e.hooks.showsWarning)
        #expect(e.state.sessions["real-1"]?.running == true)
        #expect(e.state.sessions["real-1"]?.cwd == "/tmp/project")
    }
}
