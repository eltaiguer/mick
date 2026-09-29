import Foundation

/// One item on the reminder's checklist.
public struct RoutineItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Plain, exact instruction (§10.1); nil for "Stand up".
    public var instruction: String?

    public init(id: String, title: String, instruction: String? = nil) {
        self.id = id
        self.title = title
        self.instruction = instruction
    }
}

/// What the panel shows. The engine fills `items` with a composed routine
/// (`Routine`, §10.1) and the lines from Mick's pools (`Voice`, §10.2); `standard` is
/// the fallback when no move catalogue or line pools loaded.
public struct ReminderContent: Equatable, Sendable {
    public var opener: String
    /// The plain line under the opener, or nil. Set only for a long sit with an
    /// ignored-tier opener, to say how long you've been sitting (§10.2).
    public var detail: String?
    public var items: [RoutineItem]
    /// Shown when everything is ticked (`done_all`).
    public var doneLine: String
    /// Shown when the panel is closed with some ticked (`done_partial`).
    public var partialLine: String

    public init(opener: String, detail: String? = nil, items: [RoutineItem], doneLine: String,
                partialLine: String = "Half a job. I'll take it. This time.") {
        self.opener = opener
        self.detail = detail
        self.items = items
        self.doneLine = doneLine
        self.partialLine = partialLine
    }

    /// Stand up + 2 moves (§5, decision 1).
    public static let standard = ReminderContent(
        opener: "On your feet, ya bum. The robot's doin' your job, now you do mine.",
        items: [
            RoutineItem(id: "stand", title: "Stand up"),
            RoutineItem(id: "back-bend", title: "Back bend", instruction: "Hands on your lower back, lean back gently. Hold 20s."),
            RoutineItem(id: "shoulder-rolls", title: "Shoulder rolls", instruction: "Roll your shoulders backward slowly. 10 times."),
        ],
        doneLine: "That's it. Wasn't so hard, was it?"
    )
}

extension QuietHours {
    /// True if `date` falls inside quiet hours (local time, may cross midnight). The
    /// start is inclusive and the end exclusive; equal start and end means no quiet
    /// hours. Invalid times never match.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let start = Self.minutes(start), let end = Self.minutes(end), start != end else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return start < end ? (m >= start && m < end) : (m >= start || m < end)
    }
}

/// The reminder lifecycle (SPEC §6.3 event handling, §7 trigger logic, §9.2 panel
/// lifetime), as a pure value. The app feeds it session changes, panel interactions
/// and timer fires, all with `now`; it answers with effects and the next time it needs
/// to be woken (`nextDeadline`). There is at most one reminder at a time, globally.
public struct Reminder: Equatable, Sendable {
    /// Timings from the spec. Configurable only so simulation mode (#12) can shorten them.
    public struct Timings: Equatable, Sendable {
        /// A show waits for this much input silence (§7).
        public var inputGap: TimeInterval = 3
        /// How often the gap is re-checked while waiting.
        public var gapRecheck: TimeInterval = 1
        /// The gap wait gives up this long after the first show attempt.
        public var gapGiveUp: TimeInterval = 30
        /// Nothing ticked: close this long after appearing (§9.2).
        public var untouchedClose: TimeInterval = 180
        /// Something ticked: close this long after the last tick.
        public var afterLastTick: TimeInterval = 120
        /// All ticked, or closed with some ticked: the done line shows this long.
        public var doneLine: TimeInterval = 3
        /// Close this long after appearing, no matter what.
        public var hardCap: TimeInterval = 600
        /// A reminder settles no earlier than this long after it was shown (§8).
        public var settleAfterShown: TimeInterval = 180

        public init() {}
        public static let standard = Timings()
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case scheduled(Check)
        case visible(Panel)
        case settling(Settling)
    }

    /// A reminder check waiting to fire for one session.
    public struct Check: Equatable, Sendable {
        public var sessionID: String
        /// When to try to show next (the show-delay deadline, then once a second
        /// while waiting for an input gap).
        public var fireAt: Date
        /// Set once the first show attempt found you typing: the gap wait ends here.
        public var gapGiveUpAt: Date?

        public init(sessionID: String, fireAt: Date, gapGiveUpAt: Date? = nil) {
            self.sessionID = sessionID
            self.fireAt = fireAt
            self.gapGiveUpAt = gapGiveUpAt
        }

        public var isWaitingForGap: Bool { gapGiveUpAt != nil }
    }

    /// The visible panel.
    public struct Panel: Equatable, Sendable {
        /// The session it was shown for; nil for Stretch now.
        public var sessionID: String?
        public var cwd: String?
        public var content: ReminderContent
        public var shownAt: Date
        /// Indices into `content.items`.
        public var ticked: Set<Int> = []
        /// Last time an item was ticked or unticked.
        public var lastTickAt: Date?
        /// When the last item was ticked; the done line shows from here.
        public var allTickedAt: Date?
        /// When "Not now" was chosen with some (not all) ticked; the partial done line
        /// shows from here, then the panel closes (§10.2).
        public var closingAt: Date?
        /// Whole minutes you'd been sitting when it appeared (for the reminder log).
        public var sittingMinutes: Int
        /// The longest continuous idle stretch seen since it appeared, from the idle
        /// polls of the follow-up window (§8). Only time after `shownAt` counts.
        public var maxIdleSeconds: Double = 0

        public init(sessionID: String?, cwd: String? = nil, content: ReminderContent, shownAt: Date, sittingMinutes: Int = 0) {
            self.sessionID = sessionID
            self.cwd = cwd
            self.content = content
            self.shownAt = shownAt
            self.sittingMinutes = sittingMinutes
        }

        /// Shown from the menu (Stretch now) rather than for an agent run.
        public var isManual: Bool { sessionID == nil }

        public var isDone: Bool { allTickedAt != nil }
        /// Showing a done line (all ticked, or closed with some ticked) before closing.
        public var isClosing: Bool { allTickedAt != nil || closingAt != nil }
        /// The line at the top of the panel right now: the opener, then a done line.
        public var headline: String {
            if isDone { return content.doneLine }
            if closingAt != nil { return content.partialLine }
            return content.opener
        }
        public var tickedItemIDs: [String] {
            content.items.indices.filter { ticked.contains($0) }.map { content.items[$0].id }
        }
    }

    /// A closed panel waiting to settle (§8). Blocks new reminders (decision 29).
    public struct Settling: Equatable, Sendable {
        public var panel: Panel
        public var closedAt: Date
        public var reason: CloseReason
        /// `max(closedAt, shownAt + 3 min)`; `closedAt` for a snooze. This is the
        /// reminder's `settled_at` (§8, §12.3).
        public var until: Date

        public init(panel: Panel, closedAt: Date, reason: CloseReason, until: Date) {
            self.panel = panel
            self.closedAt = closedAt
            self.reason = reason
            self.until = until
        }

        /// Whether the idle watch still runs: until the settle time, never for a snooze.
        public var isWatchingIdle: Bool { reason != .snoozed }
    }

    public enum CloseReason: String, Equatable, Sendable {
        /// The panel's session stopped, failed or asked for input with nothing ticked.
        case agentStopped
        /// Nothing ticked 3 minutes after appearing.
        case untouched
        /// 2 minutes since the last tick.
        case afterLastTick
        /// All ticked; the done line has shown.
        case done
        /// 10 minutes after appearing.
        case hardCap
        /// "Not now" (or closing the panel).
        case notNow
        /// Snooze from the panel: settles at once as the Snoozed outcome, with no idle
        /// watch (§8, decision 27).
        case snoozed
    }

    /// Why a live prompt didn't schedule a check (§7).
    public enum Blocker: Equatable, Sendable {
        case notArmed
        case snoozed
        case paused
        case quietHours
        /// A reminder is already scheduled, visible or settling.
        case busy
    }

    /// Why a scheduled check was dropped without a reminder (no penalty).
    public enum DropReason: Equatable, Sendable {
        /// Its session stopped and no other session could take the check.
        case sessionStopped
        /// Snoozed, paused or quiet hours by show time.
        case blocked(Blocker)
        /// 30 seconds without a 3-second input gap.
        case noInputGap
    }

    public enum Effect: Equatable, Sendable {
        /// A new check. `handedOffFrom` is the session whose stop cancelled the previous one.
        case scheduled(sessionID: String, fireAt: Date, handedOffFrom: String?)
        /// A re-prompt on the check's session pushed it back.
        case rescheduled(sessionID: String, fireAt: Date)
        /// A live prompt that didn't schedule anything.
        case notScheduled(sessionID: String, Blocker)
        case waitingForGap(sessionID: String)
        case dropped(sessionID: String, DropReason)
        case show(Panel)
        /// Ticks changed on the visible panel.
        case updated(Panel)
        /// Everything ticked: show the done line.
        case allTicked(Panel)
        /// "Not now" with some ticked: show the partial done line, then close as `.notNow`.
        case closing(Panel)
        case closed(Panel, CloseReason)
        /// The settle window ended. `Outcome.judge` decides how it went and
        /// `Outcome.apply` updates Mick's memory (§8).
        case settled(Settling)
    }

    public private(set) var phase: Phase = .idle
    public var timings: Timings

    public init(timings: Timings = .standard) {
        self.timings = timings
    }

    // MARK: - Queries

    public var check: Check? {
        if case .scheduled(let c) = phase { return c }
        return nil
    }

    public var panel: Panel? {
        if case .visible(let p) = phase { return p }
        return nil
    }

    public var settling: Settling? {
        if case .settling(let s) = phase { return s }
        return nil
    }

    /// Scheduled, visible or waiting to settle.
    public var isBusy: Bool { phase != .idle }

    /// When `advance` next has something to do, or nil when nothing is timed.
    public var nextDeadline: Date? {
        switch phase {
        case .idle: nil
        case .scheduled(let c): c.fireAt
        case .visible(let p): closeDeadline(p).date
        case .settling(let s): s.until
        }
    }

    /// The App Nap activity (§6.3) is needed while any session is running, a check is
    /// scheduled, or a panel is visible or waiting to settle.
    public func needsActivity(_ state: MickState) -> Bool {
        isBusy || !SessionBook.running(in: state).isEmpty
    }

    /// Whether a live prompt may schedule a check now (§7), or what blocks it.
    public func blocker(_ state: MickState, config: MickConfig, now: Date, calendar: Calendar = .current) -> Blocker? {
        if !SittingTimer.isArmed(state, config: config, now: now) { return .notArmed }
        if let b = Self.showBlocker(state, config: config, now: now, calendar: calendar) { return b }
        if isBusy { return .busy }
        return nil
    }

    /// Snoozed, paused or quiet hours: checked when scheduling and again at show time.
    static func showBlocker(_ state: MickState, config: MickConfig, now: Date, calendar: Calendar) -> Blocker? {
        if let until = state.snoozedUntil, now < until { return .snoozed }
        if state.paused { return .paused }
        if let q = config.quietHours, q.contains(now, calendar: calendar) { return .quietHours }
        return nil
    }

    // MARK: - Inputs

    /// A session change, after `SessionBook.apply` updated `state`. `canTrigger` is
    /// true only for a live `prompt` (§6.3: backlog prompts never trigger).
    public mutating func sessionChanged(
        _ change: SessionChange, sessionID: String, canTrigger: Bool,
        state: MickState, config: MickConfig, now: Date, calendar: Calendar = .current
    ) -> [Effect] {
        switch change {
        case .started:
            return prompted(sessionID: sessionID, canTrigger: canTrigger, state: state, config: config, now: now, calendar: calendar)
        case .stopped, .ended:
            return stopped(sessionID: sessionID, state: state, config: config, now: now, calendar: calendar)
        }
    }

    private mutating func prompted(sessionID: String, canTrigger: Bool, state: MickState, config: MickConfig, now: Date, calendar: Calendar) -> [Effect] {
        let delay = TimeInterval(config.showDelaySeconds)
        switch phase {
        case .scheduled(var c) where c.sessionID == sessionID:
            // A queued message or a prompt after Esc: the run restarts (§6.3).
            c.fireAt = now.addingTimeInterval(delay)
            c.gapGiveUpAt = nil
            phase = .scheduled(c)
            return [.rescheduled(sessionID: sessionID, fireAt: c.fireAt)]
        default:
            guard canTrigger else { return [] }
            if let b = blocker(state, config: config, now: now, calendar: calendar) {
                return [.notScheduled(sessionID: sessionID, b)]
            }
            let fireAt = now.addingTimeInterval(delay)
            phase = .scheduled(Check(sessionID: sessionID, fireAt: fireAt))
            return [.scheduled(sessionID: sessionID, fireAt: fireAt, handedOffFrom: nil)]
        }
    }

    private mutating func stopped(sessionID: String, state: MickState, config: MickConfig, now: Date, calendar: Calendar) -> [Effect] {
        switch phase {
        case .scheduled(let c) where c.sessionID == sessionID:
            // Cancel, and hand the check to the most recently started running session (§6.3).
            phase = .idle
            if let next = SessionBook.running(in: state).first(where: { $0.id != sessionID }),
               blocker(state, config: config, now: now, calendar: calendar) == nil {
                let start = next.session.runStartedAt ?? now
                let fireAt = max(now, start.addingTimeInterval(TimeInterval(config.showDelaySeconds)))
                phase = .scheduled(Check(sessionID: next.id, fireAt: fireAt))
                return [.scheduled(sessionID: next.id, fireAt: fireAt, handedOffFrom: sessionID)]
            }
            return [.dropped(sessionID: sessionID, .sessionStopped)]
        case .visible(let p) where p.sessionID == sessionID && p.ticked.isEmpty && !p.isDone:
            return close(p, reason: .agentStopped, now: now)
        default:
            return []
        }
    }

    /// Timers: call at (or after) `nextDeadline`. `idleSeconds` is the current system
    /// idle time, used for the input-gap check. Handles everything due at `now`.
    public mutating func advance(
        state: MickState, config: MickConfig, now: Date, idleSeconds: Double,
        content: ReminderContent = .standard, calendar: Calendar = .current
    ) -> [Effect] {
        observeIdle(idleSeconds, now: now)
        var effects: [Effect] = []
        // Each step either changes the phase or leaves nothing due, so this ends.
        for _ in 0..<8 {
            guard let due = nextDeadline, due <= now else { break }
            let step = step(state: state, config: config, now: now, idleSeconds: idleSeconds, content: content, calendar: calendar)
            effects += step
            if step.isEmpty { break }
        }
        return effects
    }

    private mutating func step(state: MickState, config: MickConfig, now: Date, idleSeconds: Double, content: ReminderContent, calendar: Calendar) -> [Effect] {
        switch phase {
        case .idle:
            return []

        case .scheduled(var c):
            // §7 show-time conditions.
            guard let session = state.sessions[c.sessionID], session.running, !session.ended else {
                phase = .idle
                return [.dropped(sessionID: c.sessionID, .sessionStopped)]
            }
            if let b = Self.showBlocker(state, config: config, now: now, calendar: calendar) {
                phase = .idle
                return [.dropped(sessionID: c.sessionID, .blocked(b))]
            }
            if idleSeconds.isFinite, idleSeconds >= timings.inputGap {
                let sitting = Int(SittingTimer.sittingSeconds(state, now: now) / 60)
                let panel = Panel(sessionID: c.sessionID, cwd: session.cwd, content: content, shownAt: now, sittingMinutes: sitting)
                phase = .visible(panel)
                return [.show(panel)]
            }
            // Mid-keystroke: re-check every second, for up to 30 s from the first try.
            let giveUp = c.gapGiveUpAt ?? now.addingTimeInterval(timings.gapGiveUp)
            if now >= giveUp {
                phase = .idle
                return [.dropped(sessionID: c.sessionID, .noInputGap)]
            }
            let firstWait = c.gapGiveUpAt == nil
            c.gapGiveUpAt = giveUp
            c.fireAt = min(now.addingTimeInterval(timings.gapRecheck), giveUp)
            phase = .scheduled(c)
            return firstWait ? [.waitingForGap(sessionID: c.sessionID)] : []

        case .visible(let p):
            let (date, reason) = closeDeadline(p)
            guard date <= now else { return [] }
            return close(p, reason: reason, now: now)

        case .settling(let s):
            guard s.until <= now else { return [] }
            phase = .idle
            return [.settled(s)]
        }
    }

    /// Stretch now (§8): shows the panel at once with no session attached, so agent
    /// stops never close it. Its lifetime is the usual one without the agent rule:
    /// closes when all items are ticked (after the done line), when you close it,
    /// 2 minutes after the last tick, or 3 minutes after appearing if untouched (and the
    /// 10-minute cap). It then settles like any reminder; `Outcome.apply` makes an
    /// Ignored manual reminder a no-op. Returns `[]` (and does nothing) while a
    /// reminder is scheduled, visible or settling. Snooze, pause and quiet hours don't
    /// block it: it's voluntary.
    public mutating func stretchNow(content: ReminderContent, sittingMinutes: Int, now: Date) -> [Effect] {
        guard phase == .idle else { return [] }
        let panel = Panel(sessionID: nil, cwd: nil, content: content, shownAt: now, sittingMinutes: sittingMinutes)
        phase = .visible(panel)
        return [.show(panel)]
    }

    /// Stretch now is available: nothing is scheduled, visible or settling (§6.4).
    public var canStretchNow: Bool { !isBusy }

    /// Ticks or unticks an item on the visible panel. Ignored once a done line shows.
    public mutating func setTicked(_ index: Int, _ isOn: Bool, now: Date) -> [Effect] {
        guard case .visible(var p) = phase, !p.isClosing, p.content.items.indices.contains(index) else { return [] }
        guard p.ticked.contains(index) != isOn else { return [] }
        if isOn { p.ticked.insert(index) } else { p.ticked.remove(index) }
        p.lastTickAt = now
        if p.ticked.count == p.content.items.count {
            p.allTickedAt = now
            phase = .visible(p)
            return [.allTicked(p)]
        }
        phase = .visible(p)
        return [.updated(p)]
    }

    /// Snooze chosen from the panel: closes and settles immediately (§8). Setting
    /// `snoozed_until` is the caller's job.
    public mutating func snooze(now: Date) -> [Effect] {
        guard case .visible(let p) = phase else { return [] }
        return close(p, reason: .snoozed, now: now)
    }

    /// Records an idle reading (seconds since the last input) taken at `now`, for the
    /// "did you get up" signal (§8). Only the part of that stretch between the panel
    /// appearing and the settle time counts. Does nothing outside the follow-up window.
    public mutating func observeIdle(_ idleSeconds: Double, now: Date) {
        guard idleSeconds.isFinite, idleSeconds > 0 else { return }
        func stretch(_ p: Panel, windowEnd: Date) -> Double {
            let start = max(now.addingTimeInterval(-idleSeconds), p.shownAt)
            return max(0, min(now, windowEnd).timeIntervalSince(start))
        }
        switch phase {
        case .visible(var p):
            let seen = stretch(p, windowEnd: now)
            guard seen > p.maxIdleSeconds else { return }
            p.maxIdleSeconds = seen
            phase = .visible(p)
        case .settling(var s) where s.isWatchingIdle:
            let seen = stretch(s.panel, windowEnd: s.until)
            guard seen > s.panel.maxIdleSeconds else { return }
            s.panel.maxIdleSeconds = seen
            phase = .settling(s)
        default:
            return
        }
    }

    /// True from the panel appearing until it settles: the idle poll runs every 5 s
    /// instead of 30 s (§6.3, §8).
    public var isInFollowUp: Bool {
        switch phase {
        case .visible: true
        case .settling(let s): s.isWatchingIdle
        default: false
        }
    }

    /// "Not now", or closing the panel. With some (not all) ticked, the partial done
    /// line shows first and the panel closes after `timings.doneLine`; a second "Not
    /// now" while it shows closes at once.
    public mutating func dismiss(now: Date) -> [Effect] {
        guard case .visible(var p) = phase else { return [] }
        if p.isDone { return close(p, reason: .done, now: now) }
        if p.ticked.isEmpty || p.closingAt != nil { return close(p, reason: .notNow, now: now) }
        p.closingAt = now
        phase = .visible(p)
        return [.closing(p)]
    }

    // MARK: - Panel lifetime (§9.2)

    /// The earliest close rule that applies to `p`, and when.
    func closeDeadline(_ p: Panel) -> (date: Date, reason: CloseReason) {
        var candidates: [(Date, CloseReason)] = [(p.shownAt.addingTimeInterval(timings.hardCap), .hardCap)]
        if let done = p.allTickedAt {
            candidates.append((done.addingTimeInterval(timings.doneLine), .done))
        } else if let closing = p.closingAt {
            candidates.append((closing.addingTimeInterval(timings.doneLine), .notNow))
        } else if !p.ticked.isEmpty, let last = p.lastTickAt {
            candidates.append((last.addingTimeInterval(timings.afterLastTick), .afterLastTick))
        } else {
            // Nothing ticked (never, or unticked again): the untouched rule.
            candidates.append((p.shownAt.addingTimeInterval(timings.untouchedClose), .untouched))
        }
        let first = candidates.min { $0.0 < $1.0 }!
        return (first.0, first.1)
    }

    private mutating func close(_ p: Panel, reason: CloseReason, now: Date) -> [Effect] {
        let until = reason == .snoozed ? now : max(now, p.shownAt.addingTimeInterval(timings.settleAfterShown))
        let s = Settling(panel: p, closedAt: now, reason: reason, until: until)
        phase = .settling(s)
        if until <= now {
            phase = .idle
            return [.closed(p, reason), .settled(s)]
        }
        return [.closed(p, reason)]
    }
}
