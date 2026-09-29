import Foundation
import Testing
@testable import MickIO
import MickCore

/// The bundled `moves.json` against the spec's table (§10.1), verbatim.
@Suite struct BundledMovesTests {
    static let table: [(id: String, title: String, instruction: String, area: String)] = [
        ("back-bend", "Back bend", "Hands on your lower back, lean back gently. Hold 20s.", "back"),
        ("forward-fold", "Forward fold", "Knees soft, let your upper body hang toward the floor. Hold 30s.", "back"),
        ("standing-twist", "Standing twist", "Feet hip-width, arms loose, turn your torso slowly side to side. 10 each way.", "back"),
        ("hip-flexor-stretch", "Hip flexor stretch", "Step one foot back, bend the front knee slightly, tuck the hips. 20s each side.", "hips"),
        ("calf-raises", "Calf raises", "Rise onto your toes, lower slowly. 15 times.", "legs"),
        ("neck-side-stretch", "Neck side stretch", "Drop one ear toward your shoulder, relax. 15s each side.", "neck"),
        ("chin-tucks", "Chin tucks", "Stand tall, pull your chin straight back, hold 3s. 8 times.", "neck"),
        ("shoulder-rolls", "Shoulder rolls", "Roll your shoulders backward slowly. 10 times.", "shoulders"),
        ("chest-opener", "Chest opener", "Clasp your hands behind your back, lift slightly, open the chest. Hold 20s.", "chest"),
        ("wrist-stretch", "Wrist stretch", "Arm out, palm up, gently pull your fingers back with the other hand. 15s each side.", "wrists"),
        ("walk", "Walk", "Walk to the kitchen and back. Refill your water.", "walk"),
    ]

    @Test func matchesTheSpecTable() throws {
        let catalog = try MoveCatalog.bundled()
        #expect(catalog.moves.count == 11)
        for (m, row) in zip(catalog.moves, Self.table) {
            #expect(m.id == row.id)
            #expect(m.title == row.title)
            #expect(m.instruction == row.instruction)
            #expect(m.area == row.area)
            #expect(m.seconds > 0 && m.seconds <= 180)
        }
        #expect(catalog.move(id: Routine.walkID)?.area == "walk")
    }

    @Test func fileHasExactlyTheSchemaKeys() throws {
        let url = try #require(MoveCatalog.bundledURL)
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for entry in raw {
            #expect(Set(entry.keys) == ["id", "title", "instruction", "area", "seconds"])
        }
    }

    @Test func instructionsArePlain() throws {
        // No personality in instructions (decision 11): no exclamations, no Mick-isms.
        for m in try MoveCatalog.bundled().moves {
            #expect(!m.instruction.contains("!"))
            for word in ["ya ", "kid", "bum", "ain't", "'"] {
                #expect(!m.instruction.lowercased().contains(word), "\(m.id): \(word)")
            }
        }
    }
}

/// Routines through the engine: composed at show time, rotation saved and kept
/// across relaunch (§10.1, §12.1).
@MainActor
@Suite(.serialized) struct RoutineEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func home(sittingMinutes: Double, rotation: MickState.Rotation = .init(), now: Date) throws -> TempHome {
        let temp = try TempHome()
        var s = MickState.defaults(now: now)
        s.sittingSince = now.addingTimeInterval(-sittingMinutes * 60)
        s.lastActiveAt = now
        s.lastEventAt = now.addingTimeInterval(-60)
        s.rotation = rotation
        try JSONFileStore.save(s, to: temp.home.state)
        try JSONFileStore.save(MickConfig(), to: temp.home.config)  // 50 min threshold
        return temp
    }

    /// Starts an engine, runs one prompt through to a shown panel, and returns what it showed.
    private func showOne(_ temp: TempHome, _ sys: FakeSystem, log: MemoryLog = MemoryLog()) async throws -> (shown: ReminderContent?, engine: MickEngine) {
        let e = MickEngine(home: temp.home, log: log, clock: { sys.now }, idleSeconds: { sys.idle })
        var shown: ReminderContent?
        e.onReminder = { fx in
            for case .show(let p) in fx { shown = p.content }
        }
        try e.start()
        e.flushTailer()
        let session = "S\(Int(sys.now.timeIntervalSince1970))"
        try temp.append(line("prompt", sys.now.timeIntervalSince1970, session))
        e.flushTailer()
        #expect(await eventually { e.reminder.check?.sessionID == session })
        sys.advance(TimeInterval(e.config.showDelaySeconds))
        e.runReminderTimers()
        return (shown, e)
    }

    private func savedState(_ temp: TempHome) -> MickState {
        JSONFileStore.load(MickState.self, from: temp.home.state, defaults: .defaults(now: t0), now: t0, log: MemoryLog()).value
    }

    @Test func aShownReminderHasARoutineAndSavesItsRotation() async throws {
        let temp = try home(sittingMinutes: 60, now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let log = MemoryLog()
        let (shown, e) = try await showOne(temp, sys, log: log)
        defer { e.stop() }
        let content = try #require(shown)
        #expect(content.items.count == 3)
        #expect(content.items[0].title == "Stand up")
        let catalog = try MoveCatalog.bundled()
        let moves = content.items.dropFirst().compactMap { catalog.move(id: $0.id) }
        #expect(moves.count == 2)
        #expect(moves[0].area != moves[1].area)
        #expect(content.items.dropFirst().map(\.instruction) == moves.map(\.instruction))

        let saved = savedState(temp)
        #expect(saved.rotation.usedMoveIDs == moves.map(\.id))
        #expect(saved.rotation.lastAreas == moves.map(\.area))
        #expect(log.messages.contains { $0.contains("routine (normal): stand, ") })
    }

    @Test func rotationSurvivesARelaunch() async throws {
        let temp = try home(sittingMinutes: 60, now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let (first, e1) = try await showOne(temp, sys)
        e1.stop()
        let firstIDs = try #require(first).items.dropFirst().map(\.id)

        // A new engine on the same home, as after a relaunch (quit briefly, so no break).
        sys.advance(60)
        let (second, e2) = try await showOne(temp, sys)
        defer { e2.stop() }
        let secondIDs = try #require(second).items.dropFirst().map(\.id)
        #expect(Set(firstIDs).isDisjoint(with: secondIDs))
        let catalog = try MoveCatalog.bundled()
        let firstAreas = Set(firstIDs.compactMap { catalog.move(id: $0)?.area })
        #expect(firstAreas.isDisjoint(with: secondIDs.compactMap { catalog.move(id: $0)?.area }))
        #expect(savedState(temp).rotation.usedMoveIDs == firstIDs + secondIDs)
    }

    @Test func aLongSitGetsTheWalk() async throws {
        let temp = try home(sittingMinutes: 100, now: t0)  // 2x the 50 min threshold
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let (shown, e) = try await showOne(temp, sys)
        defer { e.stop() }
        let items = try #require(shown).items
        #expect(items.map(\.id).prefix(2) == ["stand", "walk"])
        #expect(items.count == 3)
        #expect(savedState(temp).rotation.lastAreas.first == "walk")
    }

    @Test func aDroppedCheckLeavesTheRotationAlone() async throws {
        let start = MickState.Rotation(usedMoveIDs: ["back-bend"], lastAreas: ["back"], usedLineIDs: ["opener": ["o1"]])
        let temp = try home(sittingMinutes: 60, rotation: start, now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 0  // typing the whole time: no input gap, so no show
        let e = MickEngine(home: temp.home, log: MemoryLog(), clock: { sys.now }, idleSeconds: { sys.idle })
        try e.start()
        defer { e.stop() }
        e.flushTailer()
        try temp.append(line("prompt", t0.timeIntervalSince1970, "A"))
        e.flushTailer()
        #expect(await eventually { e.reminder.check != nil })
        for _ in 0..<40 {
            sys.advance(1)
            e.runReminderTimers()
        }
        #expect(e.reminder.panel == nil)
        #expect(savedState(temp).rotation == start)
    }

    @Test func anInjectedCatalogueIsUsed() async throws {
        let temp = try home(sittingMinutes: 60, now: t0)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = MickEngine(home: temp.home, log: MemoryLog(), clock: { sys.now }, idleSeconds: { sys.idle },
                           moves: try MoveCatalog([Move(id: "only", title: "Only", instruction: "Do it.", area: "a", seconds: 10)]))
        var shown: ReminderContent?
        e.onReminder = { fx in for case .show(let p) in fx { shown = p.content } }
        try e.start()
        defer { e.stop() }
        e.flushTailer()
        try temp.append(line("prompt", t0.timeIntervalSince1970, "A"))
        e.flushTailer()
        #expect(await eventually { e.reminder.check != nil })
        sys.advance(TimeInterval(e.config.showDelaySeconds))
        e.runReminderTimers()
        // An injected catalogue is used as is: Stand up + its one move.
        #expect(shown?.items.map(\.id) == ["stand", "only"])
    }
}
