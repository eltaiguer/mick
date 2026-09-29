import Foundation

/// One of Mick's line pools (SPEC §10.2). Raw values are the keys in `lines.json` and in
/// `state.json`'s `rotation.used_line_ids`.
public enum LinePool: String, Equatable, Hashable, Sendable, CaseIterable, Codable {
    case opener
    case openerIgnored1 = "opener_ignored_1"
    case openerIgnored2 = "opener_ignored_2"
    case openerIgnored3 = "opener_ignored_3"
    case openerLongSit = "opener_long_sit"
    case doneAll = "done_all"
    case donePartial = "done_partial"
    case snooze
    case pause
    case resume
    case statusCalm = "status_calm"
    case statusArmed = "status_armed"
    case statusGlaring = "status_glaring"
    case onboarding

    /// The panel's opening line pools.
    public var isOpener: Bool {
        switch self {
        case .opener, .openerIgnored1, .openerIgnored2, .openerIgnored3, .openerLongSit: true
        default: false
        }
    }

    /// At least 8 lines per opener pool and 5 for the rest (§10.2), so repeats stay rare.
    public var minimumLines: Int { isOpener ? 8 : 5 }

    /// The opener for a reminder (§10.2, decision 28): an ignored tier (1 / 2 / 3+) wins
    /// over long sit, which wins over normal.
    public static func opener(ignoredToday: Int, kind: Routine.Kind) -> LinePool {
        switch ignoredToday {
        case ..<1: kind == .longSit ? .openerLongSit : .opener
        case 1: .openerIgnored1
        case 2: .openerIgnored2
        default: .openerIgnored3
        }
    }

    /// The dropdown's status line pool for an icon state (§6.4). Armed and glaring have
    /// their own pools; every other state (calm, snoozed, paused, warning) uses calm.
    public static func status(for icon: MenuBarIcon) -> LinePool {
        switch icon {
        case .armed: .statusArmed
        case .glaring: .statusGlaring
        default: .statusCalm
        }
    }
}

/// One line of Mick's. The id keys rotation, so editing a line's text keeps its place.
public struct Line: Equatable, Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// The line pools from `lines.json`, validated: every pool present with enough lines,
/// unique ids, no blank text, and only the `{minutes}` and `{hours}` placeholders.
public struct LineCatalog: Equatable, Sendable {
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case missingPool(LinePool)
        case tooFewLines(LinePool, count: Int)
        case duplicateID(String)
        case blankLine(id: String)
        case unknownPlaceholder(id: String, String)

        public var description: String {
            switch self {
            case .missingPool(let p): "no \(p.rawValue) pool"
            case .tooFewLines(let p, let n): "\(p.rawValue) has \(n) lines, needs \(p.minimumLines)"
            case .duplicateID(let id): "duplicate line id \(id)"
            case .blankLine(let id): "line \(id) is blank"
            case .unknownPlaceholder(let id, let p): "line \(id) uses unknown placeholder \(p)"
            }
        }
    }

    public let pools: [LinePool: [Line]]

    public init(_ pools: [LinePool: [Line]]) throws(Problem) {
        var seen = Set<String>()
        for pool in LinePool.allCases {
            guard let lines = pools[pool] else { throw .missingPool(pool) }
            guard lines.count >= pool.minimumLines else { throw .tooFewLines(pool, count: lines.count) }
            for line in lines {
                guard !line.id.isEmpty, !line.text.trimmingCharacters(in: .whitespaces).isEmpty else { throw .blankLine(id: line.id) }
                guard seen.insert(line.id).inserted else { throw .duplicateID(line.id) }
                if let bad = SpokenTime.placeholders(in: line.text).first(where: { !SpokenTime.knownPlaceholders.contains($0) }) {
                    throw .unknownPlaceholder(id: line.id, bad)
                }
            }
        }
        self.pools = pools
    }

    /// Decodes `lines.json`: an object from pool name to an array of `{ "id", "text" }`.
    /// Unknown pool names are ignored.
    public static func decode(_ data: Data) throws -> LineCatalog {
        let raw = try JSONDecoder().decode([String: [Line]].self, from: data)
        var pools: [LinePool: [Line]] = [:]
        for (key, lines) in raw {
            if let pool = LinePool(rawValue: key) { pools[pool] = lines }
        }
        return try LineCatalog(pools)
    }

    public func lines(_ pool: LinePool) -> [Line] { pools[pool] ?? [] }

    public var allLines: [Line] { LinePool.allCases.flatMap { lines($0) } }
}

/// Line rotation (§10.2): lines rotate within a pool without repeating until the pool
/// is used up. Pure: the rotation goes in and the updated one comes out, and the caller
/// commits it to `state.json` once the line is actually shown.
public enum Lines {
    /// Picks the next line from `pool`: one not used yet in this cycle. When the pool is
    /// used up a new cycle starts, never with the line that ended the last one. Ids no
    /// longer in the catalogue are dropped from the rotation.
    public static func pick(
        _ pool: LinePool, catalog: LineCatalog, rotation: MickState.Rotation,
        using rng: inout some RandomNumberGenerator
    ) -> (line: Line, rotation: MickState.Rotation)? {
        let lines = catalog.lines(pool)
        guard !lines.isEmpty else { return nil }
        let ids = Set(lines.map(\.id))
        var used = (rotation.usedLineIDs[pool.rawValue] ?? []).filter { ids.contains($0) }
        var candidates = lines.filter { !used.contains($0.id) }
        if candidates.isEmpty {
            let last = used.last
            used = []
            candidates = lines.filter { $0.id != last }
            if candidates.isEmpty { candidates = lines }
        }
        guard let line = candidates.randomElement(using: &rng) else { return nil }
        used.append(line.id)
        var next = rotation
        next.usedLineIDs[pool.rawValue] = used
        return (line, next)
    }

    /// Records `line` as used in `pool`, for a line picked earlier but only shown now.
    /// Starts a new cycle if the pool was already used up.
    public static func markUsed(_ line: Line, in pool: LinePool, catalog: LineCatalog, rotation: inout MickState.Rotation) {
        let ids = Set(catalog.lines(pool).map(\.id))
        guard ids.contains(line.id) else { return }
        var used = (rotation.usedLineIDs[pool.rawValue] ?? []).filter { ids.contains($0) }
        if Set(used).count >= ids.count { used = [] }
        if used.contains(line.id) { return }
        used.append(line.id)
        rotation.usedLineIDs[pool.rawValue] = used
    }
}
