import Foundation
import Testing
@testable import MickIO
import MickCore

/// SPEC §15, walked end to end through the engine (issue #13).
///
/// Each test is named `acNN…` after the criterion's position in §15 (1-based), so
/// `docs/acceptance.md` can point at it and `tests/acceptance/check-matrix.sh` can check
/// the pointer is real. Events go through the real `events.jsonl` tailer in a temporary
/// MICK_HOME; the clock and idle time are fakes unless a test says otherwise. Criteria
/// that are already pinned down by a narrower test elsewhere are listed in the matrix
/// with that test instead of being repeated here.
@MainActor
@Suite(.serialized) struct AcceptanceTests {
    /// A Monday, mid-afternoon in any time zone we'd run in.
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Rig

    /// One engine on a temporary home, with the effects it delivered.
    @MainActor
    final class Rig {
        let temp: TempHome
        let sys: FakeSystem
        let log = MemoryLog()
        var engine: MickEngine
        var shows = 0
        var closes: [Reminder.CloseReason] = []
        var settled: [Outcome] = []
        /// Most panels visible at the same moment (the engine has one slot; this
        /// counts shows without a close in between).
        var maxVisible = 0
        private var visible = 0

        init(sittingMinutes: Double = 60, config: MickConfig = MickConfig(), now: Date, idle: Double = 10,
             edit: (inout MickState) -> Void = { _ in }) throws {
            temp = try TempHome()
            var s = MickState.defaults(now: now)
            s.sittingSince = now.addingTimeInterval(-sittingMinutes * 60)
            s.lastActiveAt = now
            s.lastEventAt = now.addingTimeInterval(-60)
            edit(&s)
            try JSONFileStore.save(s, to: temp.home.state)
            try JSONFileStore.save(config, to: temp.home.config)
            sys = FakeSystem(now: now)
            sys.idle = idle
            engine = MickEngine(home: temp.home, log: log, clock: { [sys] in sys.now }, idleSeconds: { [sys] in sys.idle },
                                activity: ActivityAssertion(begin: { NSObject() }, end: { _ in }))
            try launch(engine)
        }

        private func launch(_ e: MickEngine) throws {
            e.onReminder = { [unowned self] effects in
                for effect in effects {
                    switch effect {
                    case .show:
                        shows += 1; visible += 1; maxVisible = max(maxVisible, visible)
                    case .closed(_, let reason):
                        closes.append(reason); visible -= 1
                    default: break
                    }
                }
            }
            e.onSettled = { [unowned self] in settled.append($0.outcome) }
            try e.start()
            e.flushTailer()
        }

        /// Quits and relaunches on the same home (in-memory reminder state is dropped).
        func relaunch() throws {
            engine.stop()
            engine = MickEngine(home: temp.home, log: log, clock: { [sys] in sys.now }, idleSeconds: { [sys] in sys.idle },
                                activity: ActivityAssertion(begin: { NSObject() }, end: { _ in }))
            try launch(engine)
        }

        /// Appends one hook line and waits until the engine has read it.
        func send(_ kind: String, _ session: String = "A", at t: Date? = nil) async throws {
            let before = engine.state.eventsOffset
            try temp.append(line(kind, (t ?? sys.now).timeIntervalSince1970, session))
            engine.flushTailer()
            let read = await eventually { self.engine.state.eventsOffset != before }
            #expect(read, "\(kind) for \(session) never read")
        }

        /// Moves the clock one second at a time, running due reminder timers.
        func run(seconds: Int) {
            for _ in 0..<seconds {
                sys.advance(1)
                engine.runReminderTimers()
            }
        }

        /// Moves the clock in 5-second idle polls, as the follow-up poll does (§8).
        func follow(seconds: Int, idleGrows: Bool = false) {
            for _ in 0..<(seconds / 5) {
                sys.advance(5)
                if idleGrows { sys.idle += 5 }
                engine.poll()
                engine.runReminderTimers()
            }
        }

        /// Minutes of sitting the dropdown would show.
        var sittingMinutes: Double { sys.now.timeIntervalSince(engine.state.sittingSince) / 60 }

        /// Prompt, show delay, panel up.
        func showReminder(_ session: String = "A") async throws {
            try await send("prompt", session)
            run(seconds: engine.config.showDelaySeconds)
            #expect(engine.reminder.panel != nil, "no panel after the show delay")
        }

        /// A shown reminder left alone: the agent stops, nothing ticked, idle stays low.
        func ignoreReminder(_ session: String = "A") async throws {
            try await showReminder(session)
            sys.advance(5)
            try await send("stop", session)
            follow(seconds: 180)
            #expect(engine.reminder.phase == .idle)
        }

        func records() throws -> [[String: Any]] {
            guard FileManager.default.fileExists(atPath: temp.home.reminders.path) else { return [] }
            return try String(contentsOf: temp.home.reminders, encoding: .utf8).split(separator: "\n").map {
                try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }

        isolated deinit { engine.stop() }
    }

    static let hook = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // MickCore
        .deletingLastPathComponent().deletingLastPathComponent()  // repo root
        .appendingPathComponent("plugin/hooks/mick-event.sh")

    /// Runs the real plugin hook with a Claude Code payload on stdin.
    static func runHook(_ arg: String, payload: String, home: MickHome) throws {
        let process = Process()
        process.executableURL = hook
        process.arguments = [arg]
        process.environment = ["MICK_HOME": home.url.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), out = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = out
        try process.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    // MARK: - §15, in order

    /// 4. With the threshold set to 1 minute, a reminder appears on the next agent run
    /// lasting longer than the show delay.
    @Test func ac04_oneMinuteThresholdShowsOnTheNextRunLongerThanTheDelay() async throws {
        let rig = try Rig(sittingMinutes: 1.1, config: MickConfig(sitThresholdMinutes: 1), now: t0)
        #expect(rig.engine.icon == .armed)
        try await rig.send("prompt")
        rig.run(seconds: 29)
        #expect(rig.shows == 0)
        rig.run(seconds: 1)
        #expect(rig.shows == 1)
        #expect(rig.engine.reminder.panel?.sessionID == "A")
    }

    /// 5. Agent runs shorter than the show delay never produce a reminder.
    @Test func ac05_runsShorterThanTheDelayNeverShow() async throws {
        let rig = try Rig(sittingMinutes: 5, config: MickConfig(sitThresholdMinutes: 1), now: t0)
        for run in 0..<5 {
            try await rig.send("prompt", "S\(run)")
            rig.run(seconds: 29)
            try await rig.send(run.isMultiple(of: 2) ? "stop" : "wait", "S\(run)")
            rig.run(seconds: 60)
        }
        #expect(rig.shows == 0)
        #expect(rig.engine.reminder.phase == .idle)
    }

    /// 6. With nothing ticked, the panel closes within 2 s of the agent finishing,
    /// failing on an API error, or asking for tool permission. Real clock, real timer,
    /// and the real plugin hook turning each Claude Code payload into its event line.
    @Test(arguments: [
        ("stop", #"{"session_id":"R","cwd":"/tmp/p","hook_event_name":"Stop","last_assistant_message":"SECRET"}"#),
        ("stop", #"{"session_id":"R","cwd":"/tmp/p","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"SECRET"}"#),
        ("wait", #"{"session_id":"R","cwd":"/tmp/p","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"SECRET"}}"#),
        ("wait", #"{"session_id":"R","cwd":"/tmp/p","hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"SECRET"}"#),
    ])
    func ac06_untouchedPanelClosesWithinTwoSecondsOfStopFailureOrPermission(arg: String, payload: String) async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.hook.path), "hook script at \(Self.hook.path)")
        let temp = try TempHome()
        var s = MickState.defaults(now: Date())
        s.sittingSince = Date().addingTimeInterval(-3600)
        s.lastEventAt = Date()
        try JSONFileStore.save(s, to: temp.home.state)
        try JSONFileStore.save(MickConfig(showDelaySeconds: 1), to: temp.home.config)
        let e = MickEngine(home: temp.home, log: MemoryLog(), idleSeconds: { 10 },
                           activity: ActivityAssertion(begin: { NSObject() }, end: { _ in }))
        defer { e.stop() }
        try e.start()
        e.flushTailer()

        try Self.runHook("prompt", payload: #"{"session_id":"R","cwd":"/tmp/p","prompt":"SECRET"}"#, home: temp.home)
        #expect(await eventually(timeout: .seconds(5)) { e.reminder.panel != nil }, "panel never shown")

        let clock = ContinuousClock()
        let started = clock.now
        try Self.runHook(arg, payload: payload, home: temp.home)
        let closed = await eventually(timeout: .seconds(2)) { e.reminder.panel == nil && e.reminder.settling != nil }
        #expect(closed, "\(arg) didn't close the panel within 2 s")
        #expect(clock.now - started < .seconds(2))
        #expect(e.reminder.settling?.reason == .agentStopped)
        let written = try String(contentsOf: temp.home.events, encoding: .utf8)
        #expect(!written.contains("SECRET"))
    }

    /// 7. A run whose `stop` lands before its `prompt` (async ordering) leaves the
    /// session not running.
    @Test func ac07_stopLandingBeforeItsPromptLeavesTheSessionNotRunning() async throws {
        let rig = try Rig(now: t0)
        try await rig.send("stop", "A", at: t0.addingTimeInterval(0.4))
        try await rig.send("prompt", "A", at: t0)
        #expect(rig.engine.state.sessions["A"]?.running == false)
        #expect(rig.engine.reminder.check == nil)
        rig.run(seconds: 60)
        #expect(rig.shows == 0)
    }

    /// 8. After an Esc interrupt during the show delay, a panel that does appear closes
    /// after 3 minutes untouched.
    @Test func ac08_escDuringTheDelayPanelClosesAfterThreeMinutesUntouched() async throws {
        let rig = try Rig(now: t0)
        try await rig.send("prompt")
        rig.run(seconds: 10)  // Esc here: no hook fires.
        rig.run(seconds: 20)
        #expect(rig.shows == 1)
        rig.run(seconds: 179)
        #expect(rig.closes.isEmpty)
        rig.run(seconds: 1)
        #expect(rig.closes == [.untouched])
    }

    /// 9. The panel never appears while you're typing; it waits for a 3 s input gap.
    @Test func ac09_waitsForAThreeSecondInputGap() async throws {
        let rig = try Rig(now: t0, idle: 0.2)
        try await rig.send("prompt")
        rig.run(seconds: 30)
        rig.sys.idle = 2.9
        rig.run(seconds: 10)
        #expect(rig.shows == 0)
        #expect(rig.engine.reminder.check?.isWaitingForGap == true)
        rig.sys.idle = 3
        rig.run(seconds: 1)
        #expect(rig.shows == 1)
    }

    /// 10. A reminder waiting to settle blocks new ones: a prompt 1 minute after an
    /// auto-dismissed panel never schedules another.
    @Test func ac10_aPromptAMinuteAfterAnAutoDismissNeverSchedules() async throws {
        let rig = try Rig(now: t0)
        try await rig.showReminder()
        try await rig.send("stop")
        #expect(rig.closes == [.agentStopped])
        rig.follow(seconds: 60)
        try await rig.send("prompt", "B")
        #expect(rig.engine.reminder.check == nil)
        rig.follow(seconds: 120)
        rig.run(seconds: 60)
        #expect(rig.shows == 1)
    }

    /// 11. If the session a check was scheduled for stops early while another session is
    /// running, the check is handed to the running session.
    @Test func ac11_anEarlyStopHandsTheCheckToTheRunningSession() async throws {
        let rig = try Rig(now: t0)
        try await rig.send("prompt", "A")
        rig.sys.advance(5)
        try await rig.send("prompt", "B")  // blocked: A's check is scheduled
        rig.sys.advance(5)
        try await rig.send("stop", "A")
        #expect(rig.engine.reminder.check?.sessionID == "B")
        rig.run(seconds: 30)
        #expect(rig.engine.reminder.panel?.sessionID == "B")
    }

    /// 12. With one item ticked, the panel stays after the agent finishes, and closes
    /// 2 minutes after the last tick.
    @Test func ac12_oneTickKeepsThePanelUntilTwoMinutesAfterTheLastTick() async throws {
        let rig = try Rig(now: t0)
        try await rig.showReminder()
        rig.run(seconds: 10)
        rig.engine.setReminderItem(0, ticked: true)
        rig.run(seconds: 5)
        try await rig.send("stop")
        #expect(rig.engine.reminder.panel != nil)
        rig.follow(seconds: 110)
        #expect(rig.closes.isEmpty)
        rig.run(seconds: 5)
        #expect(rig.closes == [.afterLastTick])
        rig.follow(seconds: 60)
        #expect(rig.settled == [.partial])
    }

    /// 13. Three concurrent sessions never produce more than one reminder at once.
    @Test func ac13_threeConcurrentSessionsNeverShowTwoAtOnce() async throws {
        let rig = try Rig(now: t0)
        // Twenty minutes of three sessions prompting and stopping out of step.
        for step in 0..<120 {
            let session = ["A", "B", "C"][step % 3]
            try await rig.send(step % 4 == 3 ? "stop" : "prompt", session)
            rig.follow(seconds: 10)
        }
        #expect(rig.shows >= 1)
        #expect(rig.maxVisible == 1)
    }

    /// 14. After an Esc interrupt, the session's next prompt behaves normally: the run
    /// start moves to it, it schedules, shows and a stop closes it.
    @Test func ac14_afterAnEscTheNextPromptBehavesNormally() async throws {
        let rig = try Rig(sittingMinutes: 49, now: t0)
        try await rig.send("prompt")  // not armed yet: nothing scheduled
        #expect(rig.engine.reminder.check == nil)
        rig.run(seconds: 20)  // Esc: no hook, the session stays marked running
        #expect(rig.engine.state.sessions["A"]?.running == true)
        rig.follow(seconds: 120)
        let second = rig.sys.now
        try await rig.send("prompt")
        #expect(rig.engine.state.sessions["A"]?.runStartedAt.map(MickDate.micros) == MickDate.micros(second))
        #expect(rig.engine.reminder.check?.fireAt == second.addingTimeInterval(30))
        rig.run(seconds: 30)
        #expect(rig.shows == 1)
        try await rig.send("stop")
        #expect(rig.closes == [.agentStopped])
        #expect(rig.engine.state.sessions["A"]?.running == false)
    }

    /// 15. Idle for 5+ minutes, sleeping for 5+ minutes, or having Mick quit for 5+
    /// minutes resets the sitting timer.
    @Test func ac15_idleSleepOrQuitForFiveMinutesResetsSitting() async throws {
        // Idle.
        let idle = try Rig(now: t0)
        idle.sys.advance(300)
        idle.sys.idle = 300
        idle.engine.poll()
        #expect(idle.sittingMinutes < 0.1)

        // Sleep.
        let sleep = try Rig(now: t0)
        sleep.engine.willSleep()
        sleep.sys.advance(301)
        sleep.sys.idle = 0
        sleep.engine.didWake()
        #expect(sleep.sittingMinutes < 0.1)

        // Quit.
        let quit = try Rig(now: t0, idle: 0)
        quit.engine.poll()
        quit.engine.stop()
        quit.sys.advance(301)
        try quit.relaunch()
        #expect(quit.sittingMinutes < 0.1)

        // And just under five minutes does nothing.
        let short = try Rig(now: t0, idle: 0)
        short.engine.poll()
        short.sys.advance(290)
        try short.relaunch()
        #expect(short.sittingMinutes > 60)
    }

    /// 16. Snooze and pause never reset the sitting timer.
    @Test func ac16_snoozeAndPauseNeverResetSitting() async throws {
        let rig = try Rig(now: t0)
        let since = rig.engine.state.sittingSince
        for option in SnoozeOption.allCases {
            rig.engine.snooze(option)
            rig.engine.resume()
        }
        rig.engine.pause()
        rig.follow(seconds: 60)
        rig.engine.resume()
        try await rig.showReminder()
        rig.engine.snoozeReminder(until: rig.sys.now.addingTimeInterval(3600))
        #expect(rig.settled == [.snoozed])
        #expect(rig.engine.state.sittingSince == since)
    }

    /// 17. Coming back from a 40-minute break shows sitting time near zero, not 35.
    @Test func ac17_aFortyMinuteBreakLeavesSittingNearZero() async throws {
        let rig = try Rig(now: t0, idle: 0)
        rig.engine.poll()
        for _ in 0..<80 {  // 30 s polls while you're away
            rig.sys.advance(30)
            rig.sys.idle += 30
            rig.engine.poll()
        }
        rig.sys.idle = 0
        rig.sys.advance(30)
        rig.engine.poll()
        #expect(rig.sittingMinutes < 1.5)
        #expect(rig.engine.icon == .calm)
    }

    /// 18. An ignored reminder brings the next one about 25 minutes later with an
    /// `opener_ignored_*` line; a completed one waits the full threshold. Both land in
    /// the reminder log.
    @Test func ac18_ignoredComesBackInTwentyFiveMinutesCompletedWaitsTheThreshold() async throws {
        let ignored = try Rig(now: t0)
        try await ignored.ignoreReminder()
        #expect(ignored.settled == [.ignored])
        ignored.sys.advance(24 * 60)
        try await ignored.send("prompt", "B")
        #expect(ignored.engine.reminder.check == nil)
        try await ignored.send("stop", "B")
        ignored.sys.advance(60)
        try await ignored.showReminder("C")
        #expect(ignored.engine.state.rotation.usedLineIDs[LinePool.openerIgnored1.rawValue]?.count == 1)
        let tier1 = Set(ignored.engine.lines?.lines(.openerIgnored1).map(\.id) ?? [])
        #expect(ignored.engine.state.rotation.usedLineIDs[LinePool.openerIgnored1.rawValue]?.allSatisfy(tier1.contains) == true)
        #expect(try ignored.records().map { $0["outcome"] as? String } == ["ignored"])

        let completed = try Rig(now: t0)
        try await completed.showReminder()
        for i in 0..<3 { completed.engine.setReminderItem(i, ticked: true) }
        completed.follow(seconds: 180)
        #expect(completed.settled == [.completed])
        completed.sys.advance(25 * 60)
        try await completed.send("prompt", "B")
        #expect(completed.engine.reminder.check == nil)
        try await completed.send("stop", "B")
        completed.sys.advance(25 * 60)  // 50 minutes after it settled
        try await completed.showReminder("C")
        #expect(completed.engine.state.rotation.usedLineIDs[LinePool.opener.rawValue]?.count == 2)
        let log = try completed.records()
        #expect(log.map { $0["outcome"] as? String } == ["completed"])
        #expect(Set(log[0].keys) == ["shown_at", "settled_at", "session_id", "cwd", "sitting_minutes", "routine",
                                     "ticked", "max_idle_seconds", "outcome", "manual"])
    }

    /// 19. Ignoring never lowers the displayed sitting time; ignoring repeatedly still
    /// reaches the glaring icon and the long-sit routine.
    @Test func ac19_repeatedIgnoresReachGlaringAndTheLongSitWalk() async throws {
        let rig = try Rig(sittingMinutes: 50, now: t0)
        var last = rig.sittingMinutes
        var sawWalk = false
        for round in 0..<4 {
            try await rig.showReminder("S\(round)")
            if rig.engine.reminder.panel?.content.items.contains(where: { $0.id == "walk" }) == true,
               rig.engine.reminder.panel?.content.items.count == 3, rig.sittingMinutes >= 100 { sawWalk = true }
            rig.sys.advance(5)
            try await rig.send("stop", "S\(round)")
            rig.follow(seconds: 180)
            #expect(rig.sittingMinutes >= last)
            last = rig.sittingMinutes
            rig.sys.advance(25 * 60)
            #expect(rig.sittingMinutes >= last)
            last = rig.sittingMinutes
        }
        #expect(rig.settled == [.ignored, .ignored, .ignored, .ignored])
        #expect(rig.engine.icon == .glaring)
        #expect(sawWalk)
    }

    /// 20. Nothing ticked but idle >= 60 s counts as Stood up, not Ignored.
    @Test func ac20_nothingTickedButAMinuteIdleIsStoodUp() async throws {
        let rig = try Rig(now: t0, idle: 3)
        try await rig.showReminder()
        rig.follow(seconds: 65, idleGrows: true)
        rig.sys.idle = 0
        rig.follow(seconds: 120)
        #expect(rig.settled == [.stoodUp])
        #expect(rig.sittingMinutes < 0.1)
        #expect(rig.engine.state.nagAfter == nil)
    }

    /// 21. Mick's memory resets at local midnight.
    @Test func ac21_memoryResetsAtLocalMidnight() async throws {
        let calendar = Calendar.current
        let midnight = calendar.nextDate(after: t0, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)!
        let late = midnight.addingTimeInterval(-10 * 60)
        let rig = try Rig(now: late)
        try await rig.ignoreReminder()
        #expect(MickMemory.ignoredToday(rig.engine.state, now: rig.sys.now) == 1)
        rig.sys.advance(midnight.timeIntervalSince(rig.sys.now) - 1)
        rig.engine.poll()
        #expect(rig.engine.state.today.ignored == 1)
        rig.sys.advance(2)
        rig.engine.poll()
        #expect(rig.engine.state.today.ignored == 0)
        #expect(MickMemory.ignoredToday(rig.engine.state, now: rig.sys.now) == 0)
    }

    /// 22. Sitting for 2x the threshold produces the long-sit routine with a walk.
    @Test func ac22_twiceTheThresholdIsTheLongSitRoutineWithAWalk() async throws {
        // Judged at show time: 99.4 + 0.5 minutes is still a normal reminder.
        let under = try Rig(sittingMinutes: 99.4, now: t0)
        try await under.showReminder()
        #expect(under.engine.state.rotation.usedLineIDs[LinePool.openerLongSit.rawValue, default: []].isEmpty)
        #expect(under.engine.state.rotation.usedLineIDs[LinePool.opener.rawValue]?.count == 1)

        let long = try Rig(sittingMinutes: 99.6, now: t0)
        try await long.showReminder()
        let items = try #require(long.engine.reminder.panel?.content.items.map(\.id))
        #expect(items.count == 3)
        #expect(items[0] == "stand")
        #expect(items[1] == "walk")
        #expect(long.engine.state.rotation.usedLineIDs[LinePool.openerLongSit.rawValue]?.count == 1)
        #expect(long.engine.icon == .glaring)
    }

    /// 23. No routine contains two moves from the same area (bundled catalogue, sixty
    /// routines in a row; the long sit has only one move besides the walk).
    @Test func ac23_noRoutineHasTwoMovesFromTheSameArea() async throws {
        let rig = try Rig(now: t0)
        let catalog = try #require(rig.engine.moves)
        let area = Dictionary(uniqueKeysWithValues: catalog.moves.map { ($0.id, $0.area) })
        for _ in 0..<60 {
            #expect(rig.engine.stretchNow())
            let items = try #require(rig.engine.reminder.panel?.content.items)
            let areas = items.dropFirst().map { area[$0.id] }
            #expect(items.first?.id == "stand")
            #expect(areas.count == 2)
            #expect(Set(areas).count == areas.count, "\(items.map(\.id))")
            for i in 0..<items.count { rig.engine.setReminderItem(i, ticked: true) }
            rig.run(seconds: 181)
        }
        #expect(rig.shows == 60)
    }

    /// 26. Events written while Mick isn't running never trigger a reminder at launch.
    @Test func ac26_eventsWrittenWhileQuitNeverTriggerAtLaunch() async throws {
        let rig = try Rig(now: t0)
        rig.engine.stop()
        try rig.temp.append(line("prompt", t0.addingTimeInterval(1).timeIntervalSince1970, "A"))
        try rig.temp.append(line("prompt", t0.addingTimeInterval(2).timeIntervalSince1970, "B"))
        rig.sys.advance(3)
        try rig.relaunch()
        #expect(await eventually { rig.engine.state.sessions["B"]?.running == true })
        rig.run(seconds: 120)
        #expect(rig.shows == 0)
        // The next live prompt still can.
        try await rig.send("prompt", "B")
        rig.run(seconds: 30)
        #expect(rig.shows == 1)
    }

    /// 27. Corrupted state, config or event lines never crash the app; they're reset or
    /// skipped and logged.
    @Test func ac27_corruptedStateConfigAndEventLinesAreResetOrSkippedAndLogged() async throws {
        let rig = try Rig(now: t0)
        rig.engine.stop()
        try Data("{\"sitting_since\": tru".utf8).write(to: rig.temp.home.state)
        try Data([0xff, 0xfe, 0x00, 0x7b]).write(to: rig.temp.home.config)
        try rig.relaunch()
        #expect(rig.engine.config == .defaults)
        #expect(rig.engine.stateOutcome != .loaded)
        let names = try FileManager.default.contentsOfDirectory(atPath: rig.temp.home.url.path)
        #expect(names.contains { $0.hasPrefix("state.json.corrupt-") })
        #expect(names.contains { $0.hasPrefix("config.json.corrupt-") })

        try rig.temp.append("not json\n{\"e\":\"prompt\"}\n\u{00}\u{01}\n{\"e\":\"launch\",\"t\":1,\"s\":\"x\"}\n")
        try await rig.send("prompt", "A")
        #expect(await eventually { rig.log.messages.filter { $0.contains("skipped malformed event line") }.count >= 3 })
        #expect(rig.engine.state.sessions["A"]?.running == true)
        #expect(rig.engine.isRunning)
    }
}
