import Foundation
import Testing
@testable import MickCore

/// A small valid catalogue: every pool at its minimum, lines "<pool>.<n>".
private func testCatalog(extra: [LinePool: [Line]] = [:]) throws -> LineCatalog {
    var pools: [LinePool: [Line]] = [:]
    for pool in LinePool.allCases {
        pools[pool] = (1...pool.minimumLines).map { Line(id: "\(pool.rawValue).\($0)", text: "\(pool.rawValue) line \($0).") }
    }
    for (pool, lines) in extra { pools[pool] = lines }
    return try LineCatalog(pools)
}

/// `{minutes}` / `{hours}` rendering (§10.2): spelled out, capitalized at the start of a
/// sentence, lowercase elsewhere.
@Suite struct SpokenTimeTests {
    @Test(arguments: [
        (0, "zero"), (1, "one"), (7, "seven"), (13, "thirteen"), (20, "twenty"), (21, "twenty-one"),
        (47, "forty-seven"), (99, "ninety-nine"), (100, "a hundred"), (105, "a hundred and five"),
        (120, "a hundred and twenty"), (200, "two hundred"), (347, "three hundred and forty-seven"),
        (1000, "a thousand"), (1005, "a thousand and five"), (1100, "a thousand one hundred"),
        (2345, "two thousand three hundred and forty-five"),
    ])
    func numbers(_ n: Int, _ words: String) {
        #expect(SpokenTime.number(n) == words)
    }

    @Test(arguments: [
        (0, "zero minutes"), (1, "one minute"), (2, "two minutes"), (14, "fourteen minutes"),
        (15, "half an hour"), (44, "half an hour"), (45, "an hour"), (74, "an hour"),
        (75, "an hour and a half"), (100, "an hour and a half"), (104, "an hour and a half"),
        (105, "two hours"), (134, "two hours"), (135, "two and a half hours"), (165, "three hours"),
        (600, "ten hours"),
    ])
    func hoursRoundToTheNearestHalfHour(_ minutes: Int, _ words: String) {
        #expect(SpokenTime.hours(minutes) == words)
    }

    @Test func capitalizedAtTheStartOfTheLine() {
        #expect(SpokenTime.render("{minutes} minutes? You're growin' roots. Walk.", sittingMinutes: 47)
                == "Forty-seven minutes? You're growin' roots. Walk.")
        #expect(SpokenTime.render("{minutes} minutes on your can.", sittingMinutes: 105) == "A hundred and five minutes on your can.")
        #expect(SpokenTime.render("{hours} in that chair.", sittingMinutes: 100) == "An hour and a half in that chair.")
        #expect(SpokenTime.render("{hours} in that chair.", sittingMinutes: 120) == "Two hours in that chair.")
    }

    @Test func capitalizedAfterTheEndOfASentence() {
        #expect(SpokenTime.render("Kid. {hours} in that chair.", sittingMinutes: 120) == "Kid. Two hours in that chair.")
        #expect(SpokenTime.render("Up! {minutes} minutes!", sittingMinutes: 51) == "Up! Fifty-one minutes!")
        #expect(SpokenTime.render("What? \"{minutes} minutes\"", sittingMinutes: 60) == "What? \"Sixty minutes\"")
    }

    @Test func lowercaseMidSentence() {
        #expect(SpokenTime.render("You been sittin' {hours}. Walk.", sittingMinutes: 100) == "You been sittin' an hour and a half. Walk.")
        #expect(SpokenTime.render("That's {minutes} minutes in the chair.", sittingMinutes: 105) == "That's a hundred and five minutes in the chair.")
        #expect(SpokenTime.render("Kid, it's been {hours}.", sittingMinutes: 150) == "Kid, it's been two and a half hours.")
    }

    @Test func oneMinuteIsSingular() {
        #expect(SpokenTime.render("{minutes} minutes on your can.", sittingMinutes: 1) == "One minute on your can.")
        #expect(SpokenTime.render("{minutes} minutes on your can.", sittingMinutes: 2) == "Two minutes on your can.")
        #expect(SpokenTime.render("{hours} in that chair.", sittingMinutes: 1) == "One minute in that chair.")
    }

    @Test func noPlaceholdersAndUnknownOnesAreLeftAlone() {
        #expect(SpokenTime.render("About time.", sittingMinutes: 5) == "About time.")
        #expect(SpokenTime.render("A {days} thing.", sittingMinutes: 5) == "A {days} thing.")
        #expect(SpokenTime.render("Negative {minutes} minutes.", sittingMinutes: -3) == "Negative zero minutes.")
        #expect(SpokenTime.placeholders(in: "{minutes} and {hours} and {x}") == ["{minutes}", "{hours}", "{x}"])
    }

    @Test func detailAndMenuLabelsUseDigits() {
        #expect(Voice.detailLine(sittingMinutes: 107) == "Sitting 1h 47m")
        #expect(Voice.detailLine(sittingMinutes: 47) == "Sitting 47m")
    }
}

/// Which pool a line comes from (§10.2, decision 28).
@Suite struct LinePoolTests {
    @Test func openerPrecedence() {
        #expect(LinePool.opener(ignoredToday: 0, kind: .normal) == .opener)
        #expect(LinePool.opener(ignoredToday: 0, kind: .longSit) == .openerLongSit)
        #expect(LinePool.opener(ignoredToday: 1, kind: .normal) == .openerIgnored1)
        #expect(LinePool.opener(ignoredToday: 2, kind: .normal) == .openerIgnored2)
        #expect(LinePool.opener(ignoredToday: 3, kind: .normal) == .openerIgnored3)
        #expect(LinePool.opener(ignoredToday: 9, kind: .normal) == .openerIgnored3)
        // An ignored tier beats long sit.
        #expect(LinePool.opener(ignoredToday: 1, kind: .longSit) == .openerIgnored1)
        #expect(LinePool.opener(ignoredToday: 2, kind: .longSit) == .openerIgnored2)
        #expect(LinePool.opener(ignoredToday: 5, kind: .longSit) == .openerIgnored3)
    }

    @Test func statusPoolFollowsTheIcon() {
        #expect(LinePool.status(for: .calm) == .statusCalm)
        #expect(LinePool.status(for: .armed) == .statusArmed)
        #expect(LinePool.status(for: .glaring) == .statusGlaring)
        for icon in [MenuBarIcon.snoozed, .paused, .warning] {
            #expect(LinePool.status(for: icon) == .statusCalm)
        }
    }

    @Test func minimumSizes() {
        for pool in LinePool.allCases {
            #expect(pool.minimumLines == (pool.rawValue.hasPrefix("opener") ? 8 : 5))
        }
    }
}

@Suite struct LineCatalogTests {
    @Test func validates() throws {
        _ = try testCatalog()
        #expect(throws: LineCatalog.Problem.tooFewLines(.opener, count: 7)) {
            try testCatalog(extra: [.opener: (1...7).map { Line(id: "o\($0)", text: "Up.") }])
        }
        #expect(throws: LineCatalog.Problem.tooFewLines(.snooze, count: 4)) {
            try testCatalog(extra: [.snooze: (1...4).map { Line(id: "s\($0)", text: "Fine.") }])
        }
        #expect(throws: LineCatalog.Problem.duplicateID("opener.1")) {
            try testCatalog(extra: [.resume: (1...5).map { Line(id: $0 == 1 ? "opener.1" : "r\($0)", text: "Back.") }])
        }
        #expect(throws: LineCatalog.Problem.blankLine(id: "r1")) {
            try testCatalog(extra: [.resume: (1...5).map { Line(id: "r\($0)", text: $0 == 1 ? "  " : "Back.") }])
        }
        #expect(throws: LineCatalog.Problem.unknownPlaceholder(id: "r1", "{days}")) {
            try testCatalog(extra: [.resume: (1...5).map { Line(id: "r\($0)", text: $0 == 1 ? "{days} gone." : "Back.") }])
        }
        var pools = try testCatalog().pools
        pools[.onboarding] = nil
        #expect(throws: LineCatalog.Problem.missingPool(.onboarding)) { try LineCatalog(pools) }
    }

    @Test func decodesPoolsByName() throws {
        let json = try testCatalog().pools.reduce(into: [String: [[String: String]]]()) { out, entry in
            out[entry.key.rawValue] = entry.value.map { ["id": $0.id, "text": $0.text] }
        }
        var raw = json
        raw["future_pool"] = [["id": "f1", "text": "Later."]]
        let data = try JSONSerialization.data(withJSONObject: raw)
        let catalog = try LineCatalog.decode(data)
        #expect(catalog.lines(.opener).count == 8)
        #expect(catalog.allLines.count == LinePool.allCases.reduce(0) { $0 + $1.minimumLines })
    }
}

/// Rotation (§10.2): no repeats within a pool until it's used up; saved in state.json.
@Suite struct LineRotationTests {
    @Test func noRepeatsUntilThePoolIsUsedUp() throws {
        let catalog = try testCatalog()
        for seed in UInt64(1)...20 {
            var rng = SeededRNG(seed)
            var rotation = MickState.Rotation()
            var seen: [String] = []
            for _ in 0..<8 {
                let pick = try #require(Lines.pick(.opener, catalog: catalog, rotation: rotation, using: &rng))
                seen.append(pick.line.id)
                rotation = pick.rotation
            }
            #expect(Set(seen).count == 8)
            #expect(rotation.usedLineIDs["opener"] == seen)
            // Used up: a new cycle starts, and not with the line that ended the last one.
            let next = try #require(Lines.pick(.opener, catalog: catalog, rotation: rotation, using: &rng))
            #expect(next.line.id != seen.last)
            #expect(next.rotation.usedLineIDs["opener"] == [next.line.id])
        }
    }

    @Test func poolsRotateIndependently() throws {
        let catalog = try testCatalog()
        var rng = SeededRNG(7)
        let a = try #require(Lines.pick(.opener, catalog: catalog, rotation: .init(), using: &rng))
        let b = try #require(Lines.pick(.snooze, catalog: catalog, rotation: a.rotation, using: &rng))
        #expect(b.rotation.usedLineIDs["opener"] == [a.line.id])
        #expect(b.rotation.usedLineIDs["snooze"] == [b.line.id])
    }

    @Test func staleIDsAreDropped() throws {
        let catalog = try testCatalog()
        var rng = SeededRNG(3)
        let start = MickState.Rotation(usedLineIDs: ["snooze": ["gone", "snooze.1", "snooze.2"]])
        let pick = try #require(Lines.pick(.snooze, catalog: catalog, rotation: start, using: &rng))
        #expect(!["snooze.1", "snooze.2"].contains(pick.line.id))
        #expect(pick.rotation.usedLineIDs["snooze"] == ["snooze.1", "snooze.2", pick.line.id])
    }

    @Test func markUsedRecordsALineShownLater() throws {
        let catalog = try testCatalog()
        var rotation = MickState.Rotation()
        let line = catalog.lines(.doneAll)[2]
        Lines.markUsed(line, in: .doneAll, catalog: catalog, rotation: &rotation)
        Lines.markUsed(line, in: .doneAll, catalog: catalog, rotation: &rotation)
        #expect(rotation.usedLineIDs["done_all"] == [line.id])
        // A used-up pool starts a new cycle with it.
        rotation.usedLineIDs["done_all"] = catalog.lines(.doneAll).map(\.id)
        Lines.markUsed(line, in: .doneAll, catalog: catalog, rotation: &rotation)
        #expect(rotation.usedLineIDs["done_all"] == [line.id])
        // A line from another pool is ignored.
        Lines.markUsed(catalog.lines(.opener)[0], in: .doneAll, catalog: catalog, rotation: &rotation)
        #expect(rotation.usedLineIDs["done_all"] == [line.id])
    }

    @Test func rotationSurvivesStateJSON() throws {
        var state = MickState.defaults(now: Date(timeIntervalSince1970: 1_790_000_000))
        state.rotation.usedLineIDs = ["opener": ["opener.3", "opener.1"], "status_calm": ["status_calm.2"]]
        let data = try JSONEncoder.mick().encode(state)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rotation = try #require(raw["rotation"] as? [String: Any])
        #expect((rotation["used_line_ids"] as? [String: [String]])?["opener"] == ["opener.3", "opener.1"])
        let back = try JSONDecoder.mick().decode(MickState.self, from: data)
        #expect(back.rotation.usedLineIDs == state.rotation.usedLineIDs)
    }
}

/// The reminder's lines (§10.2).
@Suite struct VoiceReminderTests {
    private func lines(_ kind: Routine.Kind, ignored: Int, catalog: LineCatalog, seed: UInt64 = 1) throws -> Voice.ReminderLines {
        var rng = SeededRNG(seed)
        return try #require(Voice.pickReminderLines(kind: kind, ignoredToday: ignored, catalog: catalog, rotation: .init(), using: &rng))
    }

    @Test func picksTheOpenerByPrecedenceAndOnlyCommitsIt() throws {
        let catalog = try testCatalog()
        let cases: [(Routine.Kind, Int, LinePool)] = [
            (.normal, 0, .opener), (.longSit, 0, .openerLongSit), (.normal, 1, .openerIgnored1),
            (.longSit, 2, .openerIgnored2), (.longSit, 4, .openerIgnored3),
        ]
        for (kind, ignored, pool) in cases {
            let l = try lines(kind, ignored: ignored, catalog: catalog)
            #expect(l.openerPool == pool)
            #expect(l.opener.id.hasPrefix(pool.rawValue + "."))
            #expect(l.doneAll.id.hasPrefix("done_all."))
            #expect(l.donePartial.id.hasPrefix("done_partial."))
            #expect(l.rotation.usedLineIDs == [pool.rawValue: [l.opener.id]])
        }
    }

    @Test func detailLineOnlyForALongSitWithAnIgnoredTier() throws {
        let catalog = try testCatalog()
        for (kind, ignored, detail) in [(Routine.Kind.longSit, 1, "Sitting 1h 47m"), (.longSit, 3, "Sitting 1h 47m"),
                                        (.longSit, 0, nil), (.normal, 0, nil), (.normal, 2, nil)] as [(Routine.Kind, Int, String?)] {
            var content = ReminderContent.standard
            Voice.apply(try lines(kind, ignored: ignored, catalog: catalog), kind: kind, sittingMinutes: 107, to: &content)
            #expect(content.detail == detail)
        }
    }

    @Test func rendersThePlaceholders() throws {
        let long = (1...8).map { Line(id: "ls\($0)", text: "{minutes} minutes? Walk, kid. It's been {hours}.") }
        let catalog = try testCatalog(extra: [.openerLongSit: long,
                                              .doneAll: (1...5).map { Line(id: "da\($0)", text: "{hours}. Done.") }])
        var content = ReminderContent.standard
        let l = try lines(.longSit, ignored: 0, catalog: catalog)
        Voice.apply(l, kind: .longSit, sittingMinutes: 105, to: &content)
        #expect(content.opener == "A hundred and five minutes? Walk, kid. It's been two hours.")
        #expect(content.doneLine == "Two hours. Done.")
        #expect(content.partialLine.hasPrefix("done_partial line"))
        #expect(content.detail == nil)
    }
}

/// The voice rules themselves (the bundled file is checked in MickIOTests).
@Suite struct VoiceRulesTests {
    @Test func specExamplesPass() {
        for line in [
            "On your feet, ya bum. The robot's doin' your job, now you do mine.",
            "Up. Now. I ain't gonna say it twice.",
            "Twice today, kid. TWICE. You got glue on that chair?",
            "{minutes} minutes? You're growin' roots. Walk.",
            "{hours} in that chair. You're a disgrace to the chair.",
            "Half a job. I'll take it. This time.",
            "Fine. Go soft.",
            "About time.",
            "What the crap? Damn.",
        ] {
            #expect(VoiceRules.problems(in: line) == [], "\(line)")
        }
    }

    @Test(arguments: [
        "Sixty minutes. I'll be here.",
        "Get up for 5 minutes.",
        "Hold it 20s.",
        "Give me a minute.",
        "Half an hour and you're mine.",
        "An hour in that chair.",
        "{hours} hours in the chair.",
        "Push through the pain, kid.",
        "No pain no gain.",
        "Feel the burn!",
        "If it hurts, keep going.",
        "Get off your ass.",
        "What the hell.",
        "Holy shit, get up.",
        "Lose some weight, fatso. You're fat.",
        "Up, old man.",
        "You're stupid for sittin'.",
        "You're gonna eat lightnin' and crap thunder.",
        "Women weaken legs.",
        "Up, Rocky.",
        "It's been {days}.",
    ])
    func rulesCatchViolations(_ line: String) {
        #expect(!VoiceRules.problems(in: line).isEmpty, "\(line)")
    }
}
