import Foundation
import Testing
@testable import MickCore

/// Deterministic generator for composition tests (SplitMix64).
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func move(_ id: String, _ area: String) -> Move {
    Move(id: id, title: id, instruction: "Do \(id).", area: area, seconds: 20)
}

/// The spec's 11 moves by id and area (§10.1). The real file is checked in MickIOTests.
private let specMoves: [Move] = [
    move("back-bend", "back"), move("forward-fold", "back"), move("standing-twist", "back"),
    move("hip-flexor-stretch", "hips"), move("calf-raises", "legs"),
    move("neck-side-stretch", "neck"), move("chin-tucks", "neck"),
    move("shoulder-rolls", "shoulders"), move("chest-opener", "chest"),
    move("wrist-stretch", "wrists"), move("walk", "walk"),
]
private let catalog = try! MoveCatalog(specMoves)
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

/// Composes `count` routines in a row, feeding each one's rotation into the next.
private func run(_ count: Int, kind: (Int) -> Routine.Kind = { _ in .normal }, catalog: MoveCatalog = catalog,
                 seed: UInt64, from rotation: MickState.Rotation = .init()) -> [Routine.Composition] {
    var rng = SeededRNG(seed)
    var rotation = rotation
    var out: [Routine.Composition] = []
    for i in 0..<count {
        let c = Routine.compose(kind(i), catalog: catalog, rotation: rotation, using: &rng)
        out.append(c)
        rotation = c.rotation
    }
    return out
}

@Suite struct RoutineCompositionTests {
    @Test(arguments: 0..<50 as Range<UInt64>)
    func normalIsStandUpPlusTwoMovesFromDifferentAreas(seed: UInt64) {
        for c in run(40, seed: seed) {
            #expect(c.kind == .normal)
            #expect(c.items.count == 3)
            #expect(c.items.first == Routine.standUp)
            #expect(c.items.first?.title == "Stand up")
            #expect(c.moves.count == 2)
            #expect(c.moves[0].area != c.moves[1].area)
            #expect(c.items.dropFirst().map(\.id) == c.moves.map(\.id))
        }
    }

    @Test(arguments: 0..<30 as Range<UInt64>)
    func longSitIsStandUpPlusWalkPlusOneMove(seed: UInt64) {
        for c in run(30, kind: { _ in .longSit }, seed: seed) {
            #expect(c.items.map(\.title).prefix(2) == ["Stand up", "walk"])
            #expect(c.moves.count == 2)
            #expect(c.moves[0].id == "walk")
            #expect(c.moves[1].id != "walk")
            #expect(c.moves[1].area != "walk")
        }
    }

    @Test func itemsCarryTheInstruction() {
        var rng = SeededRNG(1)
        let c = Routine.compose(.normal, catalog: catalog, rotation: .init(), using: &rng)
        #expect(Routine.standUp.instruction == nil)
        for (item, m) in zip(c.items.dropFirst(), c.moves) {
            #expect(item == RoutineItem(id: m.id, title: m.title, instruction: m.instruction))
        }
        #expect(ReminderContent.routine(c).items == c.items)
        #expect(ReminderContent.routine(c).opener == ReminderContent.standard.opener)
    }

    // MARK: Rotation

    @Test(arguments: 0..<200 as Range<UInt64>)
    func movesDoNotRepeatUntilTheCycleIsUsedUp(seed: UInt64) {
        // Walk through many routines. A move may only come back after a new cycle has
        // started, and a new cycle only starts when no unused move fits the routine.
        var rng = SeededRNG(seed)
        var rotation = MickState.Rotation()
        var cycle = Set<String>()
        for _ in 0..<60 {
            let before = rotation
            let c = Routine.compose(.normal, catalog: catalog, rotation: rotation, using: &rng)
            let usedBefore = Set(before.usedMoveIDs)
            let rolled = !usedBefore.isSubset(of: Set(c.rotation.usedMoveIDs))
            if rolled {
                // The first pick either came from the old cycle or the roll happened at it.
                let first = c.moves[0]
                let unusedAfterFirst = catalog.moves.filter { !usedBefore.contains($0.id) && $0.id != first.id }
                let firstFromOldCycle = !usedBefore.contains(first.id)
                if firstFromOldCycle {
                    // Rolled on the second pick: nothing unused had a different area.
                    #expect(unusedAfterFirst.allSatisfy { $0.area == first.area })
                } else {
                    // Rolled on the first pick: the old cycle was used up.
                    #expect(usedBefore.count == catalog.moves.count)
                }
                cycle = Set(c.rotation.usedMoveIDs)
            } else {
                for m in c.moves {
                    #expect(!cycle.contains(m.id), "\(m.id) repeated within a cycle")
                    cycle.insert(m.id)
                }
                #expect(Set(c.rotation.usedMoveIDs) == cycle)
            }
            #expect(c.rotation.usedMoveIDs.count == Set(c.rotation.usedMoveIDs).count)
            rotation = c.rotation
        }
    }

    @Test(arguments: 0..<100 as Range<UInt64>)
    func aFullCycleUsesEveryMoveIncludingTheWalk(seed: UInt64) {
        // With the spec catalogue the area rule almost never strands a move; when a
        // cycle completes cleanly, the first 11 picks are all 11 moves.
        let picks = run(6, seed: seed).flatMap(\.moves).map(\.id)
        let firstEleven = Array(picks.prefix(11))
        if Set(firstEleven).count == 11 {
            #expect(Set(firstEleven) == Set(specMoves.map(\.id)))
        }
        // Either way no roll can happen before the 5th routine's second pick (no area has 5+ moves).
        #expect(Set(picks.prefix(9)).count == 9)
    }

    @Test func walkTakesPartInNormalRotation() {
        let seen = Set((0..<20 as Range<UInt64>).flatMap { run(6, seed: $0).flatMap(\.moves).map(\.id) })
        #expect(seen.contains("walk"))
        #expect(seen == Set(specMoves.map(\.id)))
    }

    @Test func fourAreasAlternateExactly() {
        // Four moves in four areas: routine 2 must take the two unused, and routine 3
        // starts a new cycle avoiding routine 2's areas, which leaves routine 1's pair.
        let small = try! MoveCatalog([move("a", "A"), move("b", "B"), move("c", "C"), move("d", "D")])
        for seed in 0..<20 as Range<UInt64> {
            let r = run(4, catalog: small, seed: seed).map { Set($0.moves.map(\.id)) }
            #expect(r[0].union(r[1]) == ["a", "b", "c", "d"])
            #expect(r[2] == r[0])
            #expect(r[3] == r[1])
        }
    }

    @Test func longSitMarksTheWalkUsedWithoutRollingTheCycle() {
        var rng = SeededRNG(7)
        let start = MickState.Rotation(usedMoveIDs: ["back-bend", "walk"], lastAreas: ["back", "walk"])
        let c = Routine.compose(.longSit, catalog: catalog, rotation: start, using: &rng)
        #expect(c.moves[0].id == "walk")
        #expect(!["back-bend", "walk"].contains(c.moves[1].id))
        #expect(c.rotation.usedMoveIDs == ["back-bend", "walk", c.moves[1].id])

        let fresh = Routine.compose(.longSit, catalog: catalog, rotation: .init(), using: &rng)
        #expect(fresh.rotation.usedMoveIDs == ["walk", fresh.moves[1].id])
        #expect(fresh.rotation.lastAreas == ["walk", fresh.moves[1].area])
    }

    @Test func aRollMidRoutineCarriesTheRoutinesMovesIntoTheNewCycle() {
        // Only two back moves are unused: the first pick takes one, the second can't be
        // another back move, so a new cycle starts with both of this routine's moves in it.
        let used = specMoves.map(\.id).filter { $0 != "back-bend" && $0 != "forward-fold" }
        var rng = SeededRNG(3)
        let c = Routine.compose(.normal, catalog: catalog, rotation: .init(usedMoveIDs: used, lastAreas: ["neck", "legs"]), using: &rng)
        #expect(["back-bend", "forward-fold"].contains(c.moves[0].id))
        #expect(c.moves[1].area != "back")
        #expect(c.rotation.usedMoveIDs == c.moves.map(\.id))
    }

    @Test func aUsedUpCycleStartsOver() {
        var rng = SeededRNG(5)
        let c = Routine.compose(.normal, catalog: catalog, rotation: .init(usedMoveIDs: specMoves.map(\.id)), using: &rng)
        #expect(c.moves.count == 2)
        #expect(c.rotation.usedMoveIDs == c.moves.map(\.id))
    }

    @Test func unknownUsedIDsAreDropped() {
        var rng = SeededRNG(5)
        let c = Routine.compose(.normal, catalog: catalog, rotation: .init(usedMoveIDs: ["gone", "back-bend"]), using: &rng)
        #expect(!c.rotation.usedMoveIDs.contains("gone"))
        #expect(c.rotation.usedMoveIDs.first == "back-bend")
        #expect(!c.moves.map(\.id).contains("back-bend"))
    }

    @Test func lineRotationIsLeftAlone() {
        var rng = SeededRNG(5)
        let lines = ["opener": ["o1", "o2"]]
        let c = Routine.compose(.normal, catalog: catalog, rotation: .init(usedLineIDs: lines), using: &rng)
        #expect(c.rotation.usedLineIDs == lines)
    }

    // MARK: Area rule

    @Test(arguments: 0..<200 as Range<UInt64>)
    func previousAreasAreAvoidedWhenAnAlternativeExists(seed: UInt64) {
        var rng = SeededRNG(seed)
        var rotation = MickState.Rotation()
        for _ in 0..<40 {
            let c = Routine.compose(.normal, catalog: catalog, rotation: rotation, using: &rng)
            let avoid = Set(rotation.lastAreas)
            let used = Set(rotation.usedMoveIDs)
            // First pick: if any unused move sits outside the previous areas, it must too.
            let first = c.moves[0]
            let unused = catalog.moves.filter { !used.contains($0.id) }
            if unused.contains(where: { !avoid.contains($0.area) }), !used.contains(first.id) {
                #expect(!avoid.contains(first.area), "first pick \(first.id) reused a previous area")
            }
            #expect(c.rotation.lastAreas == c.moves.map(\.area))
            rotation = c.rotation
        }
    }

    @Test func previousAreasAreAvoidedWithinACycle() {
        // Unused: shoulders, chest and a back move; the previous routine used back and
        // chest, so shoulders must come first and the second pick relaxes the rule.
        let unused: Set = ["shoulder-rolls", "chest-opener", "standing-twist"]
        let used = specMoves.map(\.id).filter { !unused.contains($0) }
        for seed in 0..<20 as Range<UInt64> {
            var rng = SeededRNG(seed)
            let c = Routine.compose(.normal, catalog: catalog, rotation: .init(usedMoveIDs: used, lastAreas: ["back", "chest"]), using: &rng)
            #expect(c.moves[0].id == "shoulder-rolls")
            #expect(["chest-opener", "standing-twist"].contains(c.moves[1].id))
        }
    }

    @Test func theAreaRuleRelaxesWhenNothingIsLeft() {
        // Two areas only: every routine has to reuse the previous routine's areas.
        let two = try! MoveCatalog([move("x1", "X"), move("x2", "X"), move("y1", "Y"), move("y2", "Y")])
        for c in run(10, catalog: two, seed: 9) {
            #expect(Set(c.moves.map(\.area)) == ["X", "Y"])
        }
        // One area: the same-routine rule relaxes too, rather than a one-move routine.
        let one = try! MoveCatalog([move("a1", "A"), move("a2", "A")])
        for c in run(5, catalog: one, seed: 9) {
            #expect(Set(c.moves.map(\.id)) == ["a1", "a2"])
        }
        // A single move: the routine is just Stand up + that move.
        let single = try! MoveCatalog([move("only", "A")])
        #expect(run(2, catalog: single, seed: 1).map { $0.moves.map(\.id) } == [["only"], ["only"]])
    }

    @Test func longSitWithoutAWalkFallsBackToTwoMoves() {
        let noWalk = try! MoveCatalog(specMoves.filter { $0.id != "walk" })
        let c = run(1, kind: { _ in .longSit }, catalog: noWalk, seed: 2)[0]
        #expect(c.moves.count == 2)
        #expect(c.moves[0].area != c.moves[1].area)
    }

    // MARK: Kind

    @Test func longSitStartsAtTwiceTheThreshold() {
        var config = MickConfig.defaults
        config.sitThresholdMinutes = 50
        var s = MickState.defaults(now: t0)
        s.sittingSince = t0.addingTimeInterval(-99 * 60)
        #expect(Routine.kind(s, config: config, now: t0) == .normal)
        s.sittingSince = t0.addingTimeInterval(-100 * 60)
        #expect(Routine.kind(s, config: config, now: t0) == .longSit)
        config.sitThresholdMinutes = 1
        s.sittingSince = t0.addingTimeInterval(-2 * 60)
        #expect(Routine.kind(s, config: config, now: t0) == .longSit)
    }

    // MARK: Catalogue

    @Test func catalogueValidation() throws {
        #expect(throws: MoveCatalog.Problem.empty) { try MoveCatalog([]) }
        #expect(throws: MoveCatalog.Problem.duplicateID("a")) { try MoveCatalog([move("a", "A"), move("a", "B")]) }
        #expect(throws: MoveCatalog.Problem.blankField(id: "a", field: "area")) { try MoveCatalog([move("a", " ")]) }
        #expect(throws: MoveCatalog.Problem.badSeconds(id: "a")) {
            try MoveCatalog([Move(id: "a", title: "A", instruction: "Do.", area: "A", seconds: 0)])
        }
        let data = Data(#"[{"id":"a","title":"A","instruction":"Do it.","area":"x","seconds":20}]"#.utf8)
        #expect(try MoveCatalog.decode(data).moves == [Move(id: "a", title: "A", instruction: "Do it.", area: "x", seconds: 20)])
        #expect(throws: (any Error).self) { try MoveCatalog.decode(Data(#"[{"id":"a"}]"#.utf8)) }
    }
}
