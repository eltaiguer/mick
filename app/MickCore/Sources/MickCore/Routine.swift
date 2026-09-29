import Foundation

/// One move from `moves.json` (SPEC §10.1).
public struct Move: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var title: String
    /// Plain and exact. The personality lives in Mick's lines, never here (decision 11).
    public var instruction: String
    public var area: String
    /// Roughly how long the move takes. Not shown in v1 (no hold timers, decision 15).
    public var seconds: Int

    public init(id: String, title: String, instruction: String, area: String, seconds: Int) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.area = area
        self.seconds = seconds
    }

    /// The panel's checklist item for this move.
    public var item: RoutineItem { RoutineItem(id: id, title: title, instruction: instruction) }
}

/// The move catalogue, validated.
public struct MoveCatalog: Equatable, Sendable {
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        case duplicateID(String)
        case blankField(id: String, field: String)
        case badSeconds(id: String)

        public var description: String {
            switch self {
            case .empty: "no moves"
            case .duplicateID(let id): "duplicate move id \(id)"
            case .blankField(let id, let field): "move \(id) has an empty \(field)"
            case .badSeconds(let id): "move \(id) has seconds <= 0"
            }
        }
    }

    public let moves: [Move]

    public init(_ moves: [Move]) throws(Problem) {
        guard !moves.isEmpty else { throw .empty }
        var seen = Set<String>()
        for m in moves {
            for (name, value) in [("id", m.id), ("title", m.title), ("instruction", m.instruction), ("area", m.area)]
            where value.trimmingCharacters(in: .whitespaces).isEmpty {
                throw .blankField(id: m.id, field: name)
            }
            guard m.seconds > 0 else { throw .badSeconds(id: m.id) }
            guard seen.insert(m.id).inserted else { throw .duplicateID(m.id) }
        }
        self.moves = moves
    }

    /// Decodes `moves.json`: a JSON array of moves.
    public static func decode(_ data: Data) throws -> MoveCatalog {
        try MoveCatalog(JSONDecoder().decode([Move].self, from: data))
    }

    public func move(id: String) -> Move? { moves.first { $0.id == id } }
}

/// Routine composition (SPEC §10.1): Stand up, then moves picked by rotation and the
/// area rule. Pure: the rotation goes in and the updated rotation comes out, and the
/// caller decides when to commit it (only when the panel actually shows).
public enum Routine {
    /// The fixed first item.
    public static let standUp = RoutineItem(id: "stand", title: "Stand up")
    /// The move a long sit always includes.
    public static let walkID = "walk"

    public enum Kind: Equatable, Sendable {
        /// Stand up + 2 moves from different areas. Also Stretch now.
        case normal
        /// Stand up + Walk + 1 move (sitting >= 2x threshold when shown).
        case longSit
    }

    public struct Composition: Equatable, Sendable {
        public var kind: Kind
        /// The moves after Stand up, in order.
        public var moves: [Move]
        /// The rotation to save once this routine is shown.
        public var rotation: MickState.Rotation

        /// Stand up followed by the moves.
        public var items: [RoutineItem] { [Routine.standUp] + moves.map(\.item) }
    }

    /// Long sit when sitting is at least twice the threshold (and Mick is armed), the
    /// same test as the glaring icon (§6.4).
    public static func kind(_ state: MickState, config: MickConfig, now: Date) -> Kind {
        SittingTimer.isGlaring(state, config: config, now: now) ? .longSit : .normal
    }

    public static func compose(
        _ kind: Kind, catalog: MoveCatalog, rotation: MickState.Rotation,
        using rng: inout some RandomNumberGenerator
    ) -> Composition {
        var used = rotation.usedMoveIDs.filter { catalog.move(id: $0) != nil }
        var picked: [Move] = []

        if kind == .longSit, let walk = catalog.move(id: walkID) {
            // The walk is fixed here; it counts as used without rolling the cycle.
            picked.append(walk)
            if !used.contains(walk.id) { used.append(walk.id) }
        }
        let avoid = Set(rotation.lastAreas)
        while picked.count < 2 {
            guard let next = pick(catalog: catalog, used: &used, picked: picked, avoidAreas: avoid, using: &rng) else { break }
            picked.append(next)
        }
        let newRotation = MickState.Rotation(
            usedMoveIDs: used,
            lastAreas: picked.map(\.area),
            usedLineIDs: rotation.usedLineIDs
        )
        return Composition(kind: kind, moves: picked, rotation: newRotation)
    }

    /// One pick. Rotation first (§10.1 rule 1): only moves unused this cycle; when
    /// none is left that fits the routine, a new cycle starts. Within that, the area
    /// rule (rule 2): a different area from moves already in this routine, and
    /// outside the previous routine's areas when possible. Relaxed in this order:
    /// previous-routine areas, then a new cycle, then (only for a catalogue with too
    /// few areas) the same-routine area rule.
    static func pick(
        catalog: MoveCatalog, used: inout [String], picked: [Move], avoidAreas: Set<String>,
        using rng: inout some RandomNumberGenerator
    ) -> Move? {
        let pickedIDs = Set(picked.map(\.id))
        let pickedAreas = Set(picked.map(\.area))
        let free = catalog.moves.filter { !pickedIDs.contains($0.id) }
        guard !free.isEmpty else { return nil }

        func best(_ pool: [Move]) -> [Move]? {
            let fresh = pool.filter { !pickedAreas.contains($0.area) }
            let ideal = fresh.filter { !avoidAreas.contains($0.area) }
            if !ideal.isEmpty { return ideal }
            return fresh.isEmpty ? nil : fresh
        }

        let usedSet = Set(used)
        if let pool = best(free.filter { !usedSet.contains($0.id) }), let m = pool.randomElement(using: &rng) {
            used.append(m.id)
            return m
        }
        // This cycle has nothing left that fits: start a new one. Moves already in
        // this routine count as used in it, so none repeats in the very next routine.
        let pool = best(free) ?? free
        guard let m = pool.randomElement(using: &rng) else { return nil }
        used = picked.map(\.id) + [m.id]
        return m
    }
}

extension ReminderContent {
    /// The standard opener and done line with a composed routine (Mick's voice, #9,
    /// replaces the lines).
    public static func routine(_ composition: Routine.Composition) -> ReminderContent {
        var content = ReminderContent.standard
        content.items = composition.items
        return content
    }
}
