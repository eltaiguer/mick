import Foundation
import Testing
@testable import MickIO
import MickCore

/// The bundled `lines.json` (§10.2) against the voice rules (§1).
@Suite struct BundledLinesTests {
    @Test func everyPoolHasEnoughLines() throws {
        let catalog = try LineCatalog.bundled()
        for pool in LinePool.allCases {
            let count = catalog.lines(pool).count
            #expect(count >= (pool.isOpener ? 8 : 5), "\(pool.rawValue): \(count)")
        }
    }

    @Test func fileHasEveryPoolAndOnlyTheSchemaKeys() throws {
        let url = try #require(LineCatalog.bundledURL)
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [[String: Any]]])
        #expect(Set(raw.keys) == Set(LinePool.allCases.map(\.rawValue)))
        for (_, lines) in raw {
            for entry in lines { #expect(Set(entry.keys) == ["id", "text"]) }
        }
    }

    @Test func everyLineFollowsTheVoiceRules() throws {
        for line in try LineCatalog.bundled().allLines {
            #expect(VoiceRules.problems(in: line.text) == [], "\(line.id): \(line.text)")
        }
    }

    @Test func noLineRepeatsAnother() throws {
        let texts = try LineCatalog.bundled().allLines.map { $0.text.lowercased() }
        #expect(Set(texts).count == texts.count)
    }

    @Test func linesAboutSittingTimeUseAPlaceholder() throws {
        let catalog = try LineCatalog.bundled()
        for pool in [LinePool.openerLongSit, .statusArmed, .statusGlaring] {
            for line in catalog.lines(pool) {
                #expect(!SpokenTime.placeholders(in: line.text).isEmpty, "\(line.id): \(line.text)")
            }
        }
        // Glaring is at least twice the threshold: said in hours.
        for line in catalog.lines(.statusGlaring) { #expect(line.text.contains("{hours}"), "\(line.id)") }
    }

    @Test func tieredOpenersNeverStateACountTheTierDoesntKnow() throws {
        // 3+ ignored could be any number: no "three times", "twice", "again twice".
        for line in try LineCatalog.bundled().lines(.openerIgnored3) {
            let lower = line.text.lowercased()
            for word in ["twice", "two", "three", "third", "second"] {
                #expect(!VoiceRules.wordList(lower).contains(word), "\(line.id): \(word)")
            }
        }
        // Tier 1 said once, never "twice".
        for line in try LineCatalog.bundled().lines(.openerIgnored1) {
            #expect(!line.text.lowercased().contains("twice"), "\(line.id)")
        }
    }

    @Test func everyLineRendersAtAnySittingTime() throws {
        for line in try LineCatalog.bundled().allLines {
            for minutes in [0, 1, 2, 47, 50, 100, 105, 135, 600] {
                let text = SpokenTime.render(line.text, sittingMinutes: minutes)
                #expect(!text.contains("{") && !text.contains("}"), "\(line.id)")
                #expect(text.first?.isUppercase == true || text.first?.isLetter == false, "\(line.id): \(text)")
            }
        }
    }
}

/// Mick's voice through the engine: the panel's lines, the status line, confirmations
/// and onboarding, with the rotation saved to `state.json`.
@MainActor
@Suite(.serialized) struct VoiceEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func home(sittingMinutes: Double, ignoredToday: Int = 0, rotation: MickState.Rotation = .init()) throws -> TempHome {
        let temp = try TempHome()
        var s = MickState.defaults(now: t0)
        s.sittingSince = t0.addingTimeInterval(-sittingMinutes * 60)
        s.lastActiveAt = t0
        s.lastEventAt = t0.addingTimeInterval(-60)
        s.today = MickState.Today(date: MickDate.localDay(t0), ignored: ignoredToday)
        s.rotation = rotation
        try JSONFileStore.save(s, to: temp.home.state)
        try JSONFileStore.save(MickConfig(), to: temp.home.config)  // 50 min threshold
        return temp
    }

    private func start(_ temp: TempHome, _ sys: FakeSystem, tunables: MickEngine.Tunables = .init()) throws -> MickEngine {
        let e = MickEngine(home: temp.home, log: MemoryLog(), tunables: tunables, clock: { sys.now }, idleSeconds: { sys.idle },
                           activity: ActivityAssertion(begin: { NSObject() }, end: { _ in }))
        try e.start()
        e.flushTailer()
        return e
    }

    private func show(_ temp: TempHome, _ e: MickEngine, _ sys: FakeSystem, session: String = "A") async throws -> Reminder.Panel {
        try temp.append(line("prompt", sys.now.timeIntervalSince1970, session))
        e.flushTailer()
        #expect(await eventually { e.reminder.check?.sessionID == session })
        sys.advance(30)
        e.runReminderTimers()
        return try #require(e.reminder.panel)
    }

    private func saved(_ temp: TempHome) -> MickState {
        JSONFileStore.load(MickState.self, from: temp.home.state, defaults: .defaults(now: .distantPast), now: Date(), log: MemoryLog()).value
    }

    private func rendered(_ pool: LinePool, minutes: Int) throws -> [String] {
        try LineCatalog.bundled().lines(pool).map { SpokenTime.render($0.text, sittingMinutes: minutes) }
    }

    private func catalogLine(id: String?) throws -> Line? {
        try LineCatalog.bundled().allLines.first { $0.id == id }
    }

    @Test(arguments: [
        // (sitting minutes, ignored today, expected pool, detail line?)
        (60.0, 0, LinePool.opener, false),
        (60.0, 1, .openerIgnored1, false),
        (60.0, 2, .openerIgnored2, false),
        (60.0, 3, .openerIgnored3, false),
        (60.0, 7, .openerIgnored3, false),
        (107.0, 0, .openerLongSit, false),
        (107.0, 1, .openerIgnored1, true),
        (107.0, 4, .openerIgnored3, true),
    ])
    func theOpenerFollowsPrecedence(_ sitting: Double, _ ignored: Int, _ pool: LinePool, _ detail: Bool) async throws {
        let temp = try home(sittingMinutes: sitting, ignoredToday: ignored)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }
        let panel = try await show(temp, e, sys)
        let minutes = Int(sitting)  // shown 30 s later, still the same whole minute
        #expect(try rendered(pool, minutes: minutes).contains(panel.content.opener), "\(panel.content.opener)")
        #expect(panel.content.detail == (detail ? "Sitting 1h 47m" : nil))
        #expect(try rendered(.doneAll, minutes: minutes).contains(panel.content.doneLine))
        #expect(try rendered(.donePartial, minutes: minutes).contains(panel.content.partialLine))
        // Only the opener is used up by showing; done lines wait until they show.
        let used = saved(temp).rotation.usedLineIDs
        #expect(used[pool.rawValue]?.count == 1)
        #expect(used["done_all"] == nil && used["done_partial"] == nil)
    }

    @Test func aLongSitOpenerSaysTheSittingTimeInWords() async throws {
        let temp = try home(sittingMinutes: 105)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }
        let opener = try await show(temp, e, sys).content.opener
        #expect(opener.contains("A hundred and five minutes") || opener.contains("Two hours") || opener.contains("two hours"), "\(opener)")
        #expect(!opener.contains { $0.isNumber })
    }

    @Test func openersDontRepeatUntilThePoolIsUsedUpAcrossRelaunches() async throws {
        let temp = try home(sittingMinutes: 60)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let pool = try LineCatalog.bundled().lines(.opener)
        var seen: [String] = []
        for i in 0..<pool.count {
            let e = try start(temp, sys)
            let panel = try await show(temp, e, sys, session: "S\(i)")
            e.dismissReminder()
            e.stop()  // relaunch between every reminder; the rotation is in state.json
            seen.append(panel.content.opener)
            // Sit on: re-arm by clearing the settle window and the nag in the saved state.
            var s = saved(temp)
            s.nagAfter = nil
            s.today.ignored = 0
            try JSONFileStore.save(s, to: temp.home.state)
            sys.advance(60)
        }
        #expect(Set(seen).count == pool.count)
        #expect(Set(saved(temp).rotation.usedLineIDs["opener"] ?? []) == Set(pool.map(\.id)))
    }

    @Test func doneLinesAreCommittedWhenTheyShow() async throws {
        let temp = try home(sittingMinutes: 60)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }
        var panel = try await show(temp, e, sys)
        for i in panel.content.items.indices { e.setReminderItem(i, ticked: true) }
        #expect(e.reminder.panel?.headline == panel.content.doneLine)
        let doneAll = try #require(try catalogLine(id: saved(temp).rotation.usedLineIDs["done_all"]?.first))
        #expect(SpokenTime.render(doneAll.text, sittingMinutes: 60) == panel.content.doneLine)

        // Settle, sit the threshold again, then close one with a single tick.
        for _ in 0..<40 { sys.advance(5); e.poll(); e.runReminderTimers() }
        #expect(e.reminder.phase == .idle)
        sys.advance(51 * 60)
        sys.idle = 10
        e.poll()
        panel = try await show(temp, e, sys, session: "B")
        e.setReminderItem(0, ticked: true)
        e.dismissReminder()
        #expect(e.reminder.panel?.headline == panel.content.partialLine)
        #expect(saved(temp).rotation.usedLineIDs["done_partial"]?.count == 1)
        sys.advance(3)
        e.runReminderTimers()
        #expect(e.reminder.panel == nil)
        #expect(e.reminder.settling?.reason == .notNow)
    }

    @Test func statusLineUsesTheCalmArmedAndGlaringPools() throws {
        let temp = try home(sittingMinutes: 47)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }
        #expect(e.icon == .calm)
        #expect(try rendered(.statusCalm, minutes: 47).contains(e.statusLine()))

        sys.advance(10 * 60)  // 57 min: armed
        #expect(e.icon == .armed)
        let armed = e.statusLine()
        #expect(try rendered(.statusArmed, minutes: 57).contains(armed), "\(armed)")
        #expect(armed.contains("ifty-seven"))

        sys.advance(45 * 60)  // 102 min: glaring
        #expect(e.icon == .glaring)
        let glaring = e.statusLine()
        #expect(try rendered(.statusGlaring, minutes: 102).contains(glaring), "\(glaring)")
        #expect(glaring.lowercased().contains("an hour and a half"))
        #expect(!glaring.contains { $0.isNumber })
        // The plain detail line keeps digits.
        #expect(e.sittingDetail == "Sitting 1h 42m · reminder armed")
    }

    @Test func statusLineKeepsItsPickUntilTheMenuOpensAgain() throws {
        let temp = try home(sittingMinutes: 10)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }
        let pool = try LineCatalog.bundled().lines(.statusCalm)
        let first = e.statusLine()
        #expect(e.statusLine() == first)
        #expect(saved(temp).rotation.usedLineIDs["status_calm"]?.count == 1)
        var ids: [String] = []
        for _ in 1..<pool.count {
            e.nextStatusLine()
            _ = e.statusLine()
        }
        ids = saved(temp).rotation.usedLineIDs["status_calm"] ?? []
        #expect(Set(ids).count == pool.count)  // rotated through the whole pool
    }

    @Test func statusLineRotationSurvivesARelaunch() throws {
        let temp = try home(sittingMinutes: 10)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let pool = try LineCatalog.bundled().lines(.statusCalm)
        for _ in 0..<pool.count {
            let e = try start(temp, sys)
            _ = e.statusLine()
            e.stop()
        }
        #expect(Set(saved(temp).rotation.usedLineIDs["status_calm"] ?? []).count == pool.count)
    }

    @Test(arguments: [LinePool.snooze, .pause, .resume])
    func confirmationsShowBrieflyInTheStatusLine(_ pool: LinePool) throws {
        let temp = try home(sittingMinutes: 10)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        var tunables = MickEngine.Tunables()
        tunables.announcementDuration = 60
        let e = try start(temp, sys, tunables: tunables)
        defer { e.stop() }
        let sittingSince = e.state.sittingSince
        let said = try #require(e.announce(pool))
        #expect(try rendered(pool, minutes: 10).contains(said))
        #expect(e.statusLine() == said)
        sys.advance(59)
        #expect(e.statusLine() == said)
        sys.advance(1)
        #expect(e.statusLine() != said)
        #expect(try rendered(.statusCalm, minutes: 11).contains(e.statusLine()))
        #expect(saved(temp).rotation.usedLineIDs[pool.rawValue]?.count == 1)
        #expect(e.state.sittingSince == sittingSince)  // confirmations never reset the timer
    }

    @Test func snoozeFromThePanelSaysASnoozeLine() async throws {
        let temp = try home(sittingMinutes: 60)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys)
        defer { e.stop() }
        _ = try await show(temp, e, sys)
        e.snoozeReminder(until: sys.now.addingTimeInterval(3600))
        #expect(try rendered(.snooze, minutes: 60).contains(e.statusLine()))
    }

    @Test func onboardingLineComesFromItsPool() throws {
        let temp = try home(sittingMinutes: 0)
        let sys = FakeSystem(now: t0)
        let e = try start(temp, sys)
        defer { e.stop() }
        let texts = try LineCatalog.bundled().lines(.onboarding).map(\.text)
        #expect(texts.contains(e.onboardingLine()))
        #expect(saved(temp).rotation.usedLineIDs["onboarding"]?.count == 1)
    }

    @Test func withoutLinesMickFallsBackToFixedOnes() throws {
        let temp = try home(sittingMinutes: 10)
        let sys = FakeSystem(now: t0)
        let e = MickEngine(home: temp.home, log: MemoryLog(), clock: { sys.now }, idleSeconds: { sys.idle },
                           lines: try LineCatalog(Dictionary(uniqueKeysWithValues: LinePool.allCases.map { pool in
                               (pool, (1...pool.minimumLines).map { Line(id: "\(pool.rawValue)\($0)", text: "Test \(pool.rawValue).") })
                           })))
        try e.start()
        defer { e.stop() }
        // An injected catalogue is used as is.
        #expect(e.statusLine() == "Test status_calm.")
        #expect(e.announce(.pause) == "Test pause.")
    }
}
