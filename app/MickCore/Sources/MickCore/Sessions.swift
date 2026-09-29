import Foundation

/// Where an event came from (SPEC §6.3). Backlog events arrived while Mick wasn't
/// running: they may update bookkeeping but never trigger anything.
public enum EventOrigin: String, Equatable, Sendable {
    case backlog, live
}

/// What applying one event did.
public enum EventDisposition: Equatable, Sendable {
    /// The session record changed. `canTrigger` is true only for a live `prompt`,
    /// the one event later tickets may schedule a reminder check from (§7).
    case applied(SessionChange, canTrigger: Bool)
    /// Older than (or as old as) the last applied event for its session (§6.3 ordering).
    case droppedOutOfOrder
    /// A backlog event 2 hours old or older: counts for hook detection only.
    case droppedStale
}

public enum SessionChange: Equatable, Sendable {
    /// `prompt`: running, with the run start at this prompt. `wasRunning` tells a
    /// re-prompt (queued message, prompt after Esc) from a new run.
    case started(wasRunning: Bool)
    /// `stop` or `wait`: not running.
    case stopped(kind: MickEvent.Kind, wasRunning: Bool)
    /// `end`: not running, and the session is gone.
    case ended(wasRunning: Bool)
}

public enum SessionBook {
    /// Backlog events at least this old don't touch session bookkeeping (§6.3).
    public static let backlogMaxAge: TimeInterval = 2 * 60 * 60
    /// Sessions with no event for this long are pruned (§6.3).
    public static let pruneAfter: TimeInterval = 2 * 60 * 60

    /// Applies one event to `state`. Any valid event, however old or out of order,
    /// proves the hooks work, so `last_event_at` moves forward first.
    @discardableResult
    public static func apply(_ event: MickEvent, origin: EventOrigin, now: Date, to state: inout MickState) -> EventDisposition {
        let eventDate = event.date
        if state.lastEventAt.map({ MickDate.micros(eventDate) > MickDate.micros($0) }) ?? true {
            state.lastEventAt = eventDate
        }

        if origin == .backlog, now.timeIntervalSince(eventDate) >= backlogMaxAge {
            return .droppedStale
        }

        let existing = state.sessions[event.sessionID]
        if let existing, MickDate.micros(eventDate) <= MickDate.micros(existing.lastEventAt) {
            return .droppedOutOfOrder
        }

        let wasRunning = existing?.running ?? false
        var session = existing ?? MickState.Session(running: false, lastEventAt: eventDate)
        session.lastEventAt = eventDate
        if let cwd = event.cwd { session.cwd = cwd }

        let change: SessionChange
        switch event.kind {
        case .prompt:
            session.running = true
            session.runStartedAt = eventDate
            session.ended = false
            change = .started(wasRunning: wasRunning)
        case .stop, .wait:
            session.running = false
            change = .stopped(kind: event.kind, wasRunning: wasRunning)
        case .end:
            session.running = false
            session.ended = true
            change = .ended(wasRunning: wasRunning)
        }
        state.sessions[event.sessionID] = session
        return .applied(change, canTrigger: origin == .live && event.kind == .prompt)
    }

    /// Removes sessions with no event for 2 hours. Returns the removed ids, sorted.
    @discardableResult
    public static func prune(_ state: inout MickState, now: Date) -> [String] {
        let stale = state.sessions.filter { now.timeIntervalSince($0.value.lastEventAt) >= pruneAfter }.keys.sorted()
        for id in stale { state.sessions[id] = nil }
        return stale
    }

    /// Sessions currently running, most recently started first.
    public static func running(in state: MickState) -> [(id: String, session: MickState.Session)] {
        state.sessions
            .filter { $0.value.running && !$0.value.ended }
            .map { (id: $0.key, session: $0.value) }
            .sorted { ($0.session.runStartedAt ?? .distantPast) > ($1.session.runStartedAt ?? .distantPast) }
    }

    /// Sessions that are live as far as the UI is concerned (not ended).
    public static func activeCount(in state: MickState) -> Int {
        state.sessions.values.filter { !$0.ended }.count
    }
}

/// One line's result, for logging and for later tickets that react to events.
public struct IntakeRecord: Equatable, Sendable {
    public var line: String
    public var result: Result<MickEvent, EventParseError>
    public var disposition: EventDisposition?

    public var event: MickEvent? { try? result.get() }
}

public enum Intake {
    /// Parses and applies a batch of lines in file order. Malformed lines are skipped
    /// (returned with a failure so the caller can log them). Afterwards, sessions with
    /// no event for 2 hours are pruned.
    public static func apply(lines: [String], origin: EventOrigin, now: Date, to state: inout MickState) -> [IntakeRecord] {
        lines.map { line in
            let result = EventParser.parse(line)
            switch result {
            case .success(let event):
                let disposition = SessionBook.apply(event, origin: origin, now: now, to: &state)
                return IntakeRecord(line: line, result: result, disposition: disposition)
            case .failure:
                return IntakeRecord(line: line, result: result, disposition: nil)
            }
        }
    }
}
