import Foundation
import Testing
@testable import MickCore

private let t0 = 1_790_000_000.0
private let now = Date(timeIntervalSince1970: t0 + 60)

private func ev(_ kind: MickEvent.Kind, _ t: Double, _ s: String = "A", cwd: String? = "/p") -> MickEvent {
    MickEvent(kind: kind, time: t, sessionID: s, cwd: cwd)
}

private func fresh() -> MickState { .defaults(now: Date(timeIntervalSince1970: t0 - 3600)) }

@Suite struct SessionBookTests {
    // MARK: running / not running

    @Test func promptMarksRunningAndRecordsRunStart() {
        var state = fresh()
        let d = SessionBook.apply(ev(.prompt, t0), origin: .live, now: now, to: &state)
        #expect(d == .applied(.started(wasRunning: false), canTrigger: true))
        let s = state.sessions["A"]!
        #expect(s.running)
        #expect(s.runStartedAt == Date(timeIntervalSince1970: t0))
        #expect(s.lastEventAt == Date(timeIntervalSince1970: t0))
        #expect(s.cwd == "/p")
    }

    @Test(arguments: [MickEvent.Kind.stop, .wait])
    func stopAndWaitMarkNotRunning(kind: MickEvent.Kind) {
        var state = fresh()
        SessionBook.apply(ev(.prompt, t0), origin: .live, now: now, to: &state)
        let d = SessionBook.apply(ev(kind, t0 + 5), origin: .live, now: now, to: &state)
        #expect(d == .applied(.stopped(kind: kind, wasRunning: true), canTrigger: false))
        #expect(state.sessions["A"]?.running == false)
        #expect(state.sessions["A"]?.runStartedAt == Date(timeIntervalSince1970: t0))
    }

    @Test func endMarksNotRunningAndEnded() {
        var state = fresh()
        SessionBook.apply(ev(.prompt, t0), origin: .live, now: now, to: &state)
        let d = SessionBook.apply(ev(.end, t0 + 5), origin: .live, now: now, to: &state)
        #expect(d == .applied(.ended(wasRunning: true), canTrigger: false))
        #expect(state.sessions["A"]?.running == false)
        #expect(state.sessions["A"]?.ended == true)
        #expect(SessionBook.running(in: state).isEmpty)
        #expect(SessionBook.activeCount(in: state) == 0)
    }

    @Test func rePromptResetsTheRunStart() {
        var state = fresh()
        SessionBook.apply(ev(.prompt, t0), origin: .live, now: now, to: &state)
        let d = SessionBook.apply(ev(.prompt, t0 + 20), origin: .live, now: now, to: &state)
        #expect(d == .applied(.started(wasRunning: true), canTrigger: true))
        #expect(state.sessions["A"]?.runStartedAt == Date(timeIntervalSince1970: t0 + 20))
    }

    @Test func stopForAnUnknownSessionCreatesItNotRunning() {
        var state = fresh()
        let d = SessionBook.apply(ev(.stop, t0), origin: .live, now: now, to: &state)
        #expect(d == .applied(.stopped(kind: .stop, wasRunning: false), canTrigger: false))
        #expect(state.sessions["A"]?.running == false)
    }

    @Test func sessionsAreIndependent() {
        var state = fresh()
        SessionBook.apply(ev(.prompt, t0, "A"), origin: .live, now: now, to: &state)
        SessionBook.apply(ev(.prompt, t0 + 1, "B"), origin: .live, now: now, to: &state)
        SessionBook.apply(ev(.stop, t0 + 2, "A"), origin: .live, now: now, to: &state)
        #expect(state.sessions["A"]?.running == false)
        #expect(state.sessions["B"]?.running == true)
        #expect(SessionBook.running(in: state).map(\.id) == ["B"])
    }

    @Test func runningIsMostRecentlyStartedFirst() {
        var state = fresh()
        SessionBook.apply(ev(.prompt, t0, "A"), origin: .live, now: now, to: &state)
        SessionBook.apply(ev(.prompt, t0 + 2, "B"), origin: .live, now: now, to: &state)
        SessionBook.apply(ev(.prompt, t0 + 1, "C"), origin: .live, now: now, to: &state)
        #expect(SessionBook.running(in: state).map(\.id) == ["B", "C", "A"])
    }

    // MARK: ordering

    @Test func aPromptLandingAfterItsOwnStopIsDropped() {
        var state = fresh()
        SessionBook.apply(ev(.stop, t0 + 3), origin: .live, now: now, to: &state)
        let d = SessionBook.apply(ev(.prompt, t0), origin: .live, now: now, to: &state)
        #expect(d == .droppedOutOfOrder)
        #expect(state.sessions["A"]?.running == false)
        #expect(state.sessions["A"]?.lastEventAt == Date(timeIntervalSince1970: t0 + 3))
    }

    @Test func anEventWithTheSameTimeIsDropped() {
        var state = fresh()
        SessionBook.apply(ev(.prompt, t0), origin: .live, now: now, to: &state)
        #expect(SessionBook.apply(ev(.stop, t0), origin: .live, now: now, to: &state) == .droppedOutOfOrder)
        #expect(state.sessions["A"]?.running == true)
    }

    @Test func orderingIsPerSession() {
        var state = fresh()
        SessionBook.apply(ev(.stop, t0 + 10, "A"), origin: .live, now: now, to: &state)
        let d = SessionBook.apply(ev(.prompt, t0, "B"), origin: .live, now: now, to: &state)
        #expect(d == .applied(.started(wasRunning: false), canTrigger: true))
    }

    @Test func orderingHoldsAtMicrosecondsAcrossASaveAndReload() throws {
        var state = fresh()
        SessionBook.apply(ev(.stop, t0 + 0.000_200), origin: .live, now: now, to: &state)
        let data = try JSONEncoder.mick().encode(state)
        var reloaded = try JSONDecoder.mick().decode(MickState.self, from: data)
        #expect(SessionBook.apply(ev(.prompt, t0 + 0.000_100), origin: .live, now: now, to: &reloaded) == .droppedOutOfOrder)
        #expect(SessionBook.apply(ev(.prompt, t0 + 0.000_300), origin: .live, now: now, to: &reloaded) != .droppedOutOfOrder)
    }

    @Test func aLatePromptCantResurrectAnEndedSession() {
        var state = fresh()
        SessionBook.apply(ev(.end, t0 + 5), origin: .live, now: now, to: &state)
        #expect(SessionBook.apply(ev(.prompt, t0 + 1), origin: .live, now: now, to: &state) == .droppedOutOfOrder)
        #expect(SessionBook.running(in: state).isEmpty)
    }

    @Test func aNewerPromptAfterEndStartsAgain() {
        // Session ids are unique per session, so this shouldn't happen, but if it
        // does the newer prompt wins like any other event.
        var state = fresh()
        SessionBook.apply(ev(.end, t0), origin: .live, now: now, to: &state)
        SessionBook.apply(ev(.prompt, t0 + 1), origin: .live, now: now, to: &state)
        #expect(state.sessions["A"]?.ended == false)
        #expect(SessionBook.running(in: state).map(\.id) == ["A"])
    }

    // MARK: backlog

    @Test func recentBacklogUpdatesBookkeepingButNeverTriggers() {
        var state = fresh()
        let d = SessionBook.apply(ev(.prompt, now.timeIntervalSince1970 - 60 * 60), origin: .backlog, now: now, to: &state)
        #expect(d == .applied(.started(wasRunning: false), canTrigger: false))
        #expect(state.sessions["A"]?.running == true)
    }

    @Test func backlogTwoHoursOldIsIgnoredForBookkeeping() {
        var state = fresh()
        let old = now.timeIntervalSince1970 - 2 * 60 * 60
        #expect(SessionBook.apply(ev(.prompt, old), origin: .backlog, now: now, to: &state) == .droppedStale)
        #expect(state.sessions.isEmpty)
        // ...but it still proves the hooks work.
        #expect(state.lastEventAt == Date(timeIntervalSince1970: old))
    }

    @Test func backlogJustUnderTwoHoursCounts() {
        var state = fresh()
        let recent = now.timeIntervalSince1970 - 2 * 60 * 60 + 1
        #expect(SessionBook.apply(ev(.stop, recent), origin: .backlog, now: now, to: &state) != .droppedStale)
        #expect(state.sessions["A"] != nil)
    }

    @Test func onlyLivePromptsCanTrigger() {
        for kind in MickEvent.Kind.allCases {
            for origin in [EventOrigin.live, .backlog] {
                var state = fresh()
                let d = SessionBook.apply(ev(kind, t0), origin: origin, now: now, to: &state)
                guard case .applied(_, let canTrigger) = d else { Issue.record("not applied"); continue }
                #expect(canTrigger == (kind == .prompt && origin == .live), "\(kind) \(origin)")
            }
        }
    }

    // MARK: last_event_at

    @Test func lastEventAtIsTheNewestEventSeen() {
        var state = fresh()
        #expect(state.lastEventAt == nil)
        SessionBook.apply(ev(.stop, t0 + 5), origin: .live, now: now, to: &state)
        SessionBook.apply(ev(.prompt, t0), origin: .live, now: now, to: &state)  // out of order
        #expect(state.lastEventAt == Date(timeIntervalSince1970: t0 + 5))
        SessionBook.apply(ev(.prompt, t0 + 9, "B"), origin: .live, now: now, to: &state)
        #expect(state.lastEventAt == Date(timeIntervalSince1970: t0 + 9))
    }

    // MARK: pruning

    @Test func prunesSessionsWithNoEventForTwoHours() {
        var state = fresh()
        let base = now.timeIntervalSince1970
        SessionBook.apply(ev(.prompt, base - 2 * 3600 - 1, "old-running"), origin: .live, now: now, to: &state)
        SessionBook.apply(ev(.end, base - 2 * 3600, "old-ended"), origin: .live, now: now, to: &state)
        SessionBook.apply(ev(.prompt, base - 2 * 3600 + 1, "recent"), origin: .live, now: now, to: &state)
        let removed = SessionBook.prune(&state, now: now)
        #expect(removed == ["old-ended", "old-running"])
        #expect(Array(state.sessions.keys) == ["recent"])
    }

    // MARK: batches

    @Test func intakeAppliesInOrderAndSkipsMalformedLines() {
        var state = fresh()
        let lines = [
            #"{"e":"prompt","t":\#(t0),"s":"A","c":"/a","n":null}"#,
            "garbage",
            #"{"e":"prompt","t":\#(t0 + 1),"s":"B","c":"/b","n":null}"#,
            #"{"e":"stop","t":\#(t0 + 2),"s":"A","c":"/a","n":null}"#,
        ]
        let records = Intake.apply(lines: lines, origin: .live, now: now, to: &state)
        #expect(records.count == 4)
        #expect(records[1].event == nil)
        #expect(records[1].disposition == nil)
        #expect(records[3].disposition == .applied(.stopped(kind: .stop, wasRunning: true), canTrigger: false))
        #expect(state.sessions["A"]?.running == false)
        #expect(state.sessions["B"]?.running == true)
    }
}
