import Foundation

/// `state.json` (SPEC §12.1): what must survive a relaunch. Missing keys take their
/// defaults so older files keep loading as fields are added.
public struct MickState: Equatable, Sendable, Codable {
    public var sittingSince: Date
    public var lastActiveAt: Date
    /// Newest event time seen from the hooks, live or backlog. Nil until the hooks are
    /// detected; drives the warning icon (§6.4).
    public var lastEventAt: Date?
    public var snoozedUntil: Date?
    public var nagAfter: Date?
    public var paused: Bool
    public var today: Today
    public var rotation: Rotation
    public var sessions: [String: Session]
    /// Bytes of `events.jsonl` already read.
    public var eventsOffset: UInt64

    public init(
        sittingSince: Date,
        lastActiveAt: Date,
        lastEventAt: Date? = nil,
        snoozedUntil: Date? = nil,
        nagAfter: Date? = nil,
        paused: Bool = false,
        today: Today,
        rotation: Rotation = Rotation(),
        sessions: [String: Session] = [:],
        eventsOffset: UInt64 = 0
    ) {
        self.sittingSince = sittingSince
        self.lastActiveAt = lastActiveAt
        self.lastEventAt = lastEventAt
        self.snoozedUntil = snoozedUntil
        self.nagAfter = nagAfter
        self.paused = paused
        self.today = today
        self.rotation = rotation
        self.sessions = sessions
        self.eventsOffset = eventsOffset
    }

    /// Fresh state for a first launch (or after a corrupt `state.json`).
    public static func defaults(now: Date, calendar: Calendar = .current) -> MickState {
        MickState(sittingSince: now, lastActiveAt: now, today: Today(date: MickDate.localDay(now, calendar: calendar), ignored: 0))
    }

    public struct Today: Equatable, Sendable, Codable {
        public var date: String
        public var ignored: Int

        public init(date: String, ignored: Int = 0) {
            self.date = date
            self.ignored = ignored
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(String.self, forKey: .date)
            ignored = try c.decodeIfPresent(Int.self, forKey: .ignored) ?? 0
        }
    }

    public struct Rotation: Equatable, Sendable, Codable {
        public var usedMoveIDs: [String]
        public var lastAreas: [String]
        public var usedLineIDs: [String: [String]]

        public init(usedMoveIDs: [String] = [], lastAreas: [String] = [], usedLineIDs: [String: [String]] = [:]) {
            self.usedMoveIDs = usedMoveIDs
            self.lastAreas = lastAreas
            self.usedLineIDs = usedLineIDs
        }

        enum CodingKeys: String, CodingKey {
            case usedMoveIDs = "used_move_ids"
            case lastAreas = "last_areas"
            case usedLineIDs = "used_line_ids"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedMoveIDs = try c.decodeIfPresent([String].self, forKey: .usedMoveIDs) ?? []
            lastAreas = try c.decodeIfPresent([String].self, forKey: .lastAreas) ?? []
            usedLineIDs = try c.decodeIfPresent([String: [String]].self, forKey: .usedLineIDs) ?? [:]
        }
    }

    public struct Session: Equatable, Sendable, Codable {
        public var running: Bool
        public var runStartedAt: Date?
        /// Time (`t`) of the last event applied for this session; the ordering key.
        public var lastEventAt: Date
        public var cwd: String?
        /// Set by an `end` event. The record stays (not running) until the 2-hour
        /// prune so a late async event from the same session can't bring it back.
        public var ended: Bool

        public init(running: Bool, runStartedAt: Date? = nil, lastEventAt: Date, cwd: String? = nil, ended: Bool = false) {
            self.running = running
            self.runStartedAt = runStartedAt
            self.lastEventAt = lastEventAt
            self.cwd = cwd
            self.ended = ended
        }

        enum CodingKeys: String, CodingKey {
            case running
            case runStartedAt = "run_started_at"
            case lastEventAt = "last_event_at"
            case cwd
            case ended
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
            runStartedAt = try c.decodeIfPresent(Date.self, forKey: .runStartedAt)
            lastEventAt = try c.decode(Date.self, forKey: .lastEventAt)
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            ended = try c.decodeIfPresent(Bool.self, forKey: .ended) ?? false
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(running, forKey: .running)
            try c.encode(runStartedAt, forKey: .runStartedAt)
            try c.encode(lastEventAt, forKey: .lastEventAt)
            try c.encodeIfPresent(cwd, forKey: .cwd)
            if ended { try c.encode(true, forKey: .ended) }
        }
    }

    enum CodingKeys: String, CodingKey {
        case sittingSince = "sitting_since"
        case lastActiveAt = "last_active_at"
        case lastEventAt = "last_event_at"
        case snoozedUntil = "snoozed_until"
        case nagAfter = "nag_after"
        case paused
        case today
        case rotation
        case sessions
        case eventsOffset = "events_offset"
    }

    /// Decodes with defaults for missing keys. `now` fills `sitting_since`,
    /// `last_active_at` and `today` if they're absent.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        sittingSince = try c.decodeIfPresent(Date.self, forKey: .sittingSince) ?? now
        lastActiveAt = try c.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? now
        lastEventAt = try c.decodeIfPresent(Date.self, forKey: .lastEventAt)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        nagAfter = try c.decodeIfPresent(Date.self, forKey: .nagAfter)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        today = try c.decodeIfPresent(Today.self, forKey: .today) ?? Today(date: MickDate.localDay(now))
        rotation = try c.decodeIfPresent(Rotation.self, forKey: .rotation) ?? Rotation()
        sessions = try c.decodeIfPresent([String: Session].self, forKey: .sessions) ?? [:]
        eventsOffset = try c.decodeIfPresent(UInt64.self, forKey: .eventsOffset) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sittingSince, forKey: .sittingSince)
        try c.encode(lastActiveAt, forKey: .lastActiveAt)
        try c.encode(lastEventAt, forKey: .lastEventAt)
        try c.encode(snoozedUntil, forKey: .snoozedUntil)
        try c.encode(nagAfter, forKey: .nagAfter)
        try c.encode(paused, forKey: .paused)
        try c.encode(today, forKey: .today)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(sessions, forKey: .sessions)
        try c.encode(eventsOffset, forKey: .eventsOffset)
    }
}
