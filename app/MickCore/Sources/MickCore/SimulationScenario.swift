import Foundation

/// A scripted multi-session replay for simulation mode (SPEC §16, issue #12): hook
/// events to write at set times, and what should be true at set times. Pure data;
/// `MickIO.SimulationRun` plays it against a real engine and the app shows the real
/// panel. Timings assume `SimulationScenario.config` (1-minute thresholds, 5 s delay).
public struct SimulationScenario: Equatable, Sendable, Identifiable {
    public enum ID: String, Equatable, Sendable, CaseIterable {
        case normalRun = "normal-run"
        case shortRun = "short-run"
        case escInterrupt = "esc-interrupt"
        case permissionPause = "permission-pause"
        case threeSessions = "three-sessions"
        case handOff = "hand-off"
        case outOfOrder = "out-of-order"
    }

    public struct Step: Equatable, Sendable {
        /// Seconds after the run starts.
        public var at: TimeInterval
        public var action: Action

        public init(at: TimeInterval, _ action: Action) {
            self.at = at
            self.action = action
        }
    }

    public enum Action: Equatable, Sendable {
        /// Append a hook event to `events.jsonl`. Its `t` is `start + t` (not the write
        /// time), so a script can make events land out of order.
        case event(MickEvent.Kind, session: String, t: TimeInterval)
        case expect(Expectation)
    }

    public enum Expectation: Equatable, Sendable {
        /// The panel is on screen, for this session.
        case visible(session: String)
        /// No panel on screen.
        case hidden
        /// A check is scheduled for this session. `fireAt` (seconds after the start),
        /// when given, must match to within half a second.
        case scheduled(session: String, fireAt: TimeInterval? = nil)
        /// Nothing scheduled or visible (a settling reminder still counts as nothing).
        case nothingScheduled
        /// The most recent close had this reason.
        case closed(Reminder.CloseReason)
        /// Mick's bookkeeping has this session running (or not).
        case running(session: String, Bool)
        /// Panels shown so far in this run.
        case shows(Int)
    }

    public var id: ID
    public var title: String
    /// What you should see, in one or two plain sentences.
    public var summary: String
    public var steps: [Step]

    public init(id: ID, title: String, summary: String, steps: [Step]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.steps = steps.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
    }

    /// When the run is over: a second after the last step.
    public var duration: TimeInterval { (steps.last?.at ?? 0) + 1 }

    public var expectations: [(at: TimeInterval, Expectation)] {
        steps.compactMap { if case .expect(let e) = $0.action { ($0.at, e) } else { nil } }
    }

    // MARK: - Simulation settings (SPEC §16)

    /// 1-minute thresholds and a 5-second show delay.
    public static let config = MickConfig(sitThresholdMinutes: 1, breakResetMinutes: 1, showDelaySeconds: 5)
    /// A simulation starts armed: sitting for twice the threshold (so no one waits a
    /// minute first), hooks already seen.
    public static let sittingAtStart: TimeInterval = 2 * 60

    public static func initialState(now: Date) -> MickState {
        var s = MickState.defaults(now: now)
        s.sittingSince = now.addingTimeInterval(-sittingAtStart)
        s.lastActiveAt = now
        s.lastEventAt = now
        return s
    }

    /// The working directory in simulated events.
    public static let cwd = "/tmp/mick-simulation"

    // MARK: - Scenarios

    public static func named(_ id: ID) -> SimulationScenario {
        all.first { $0.id == id }!
    }

    /// Every scenario, in menu order. Offsets use the 5 s delay; checks after a stop
    /// or wait sit 1.5 s later, inside the 2 s close requirement (§9.2).
    public static let all: [SimulationScenario] = {
        let delay = TimeInterval(config.showDelaySeconds)
        let untouched = Reminder.Timings.standard.untouchedClose
        func prompt(_ s: String, _ at: TimeInterval) -> Step { Step(at: at, .event(.prompt, session: s, t: at)) }
        func stop(_ s: String, _ at: TimeInterval) -> Step { Step(at: at, .event(.stop, session: s, t: at)) }
        func expect(_ at: TimeInterval, _ e: Expectation) -> Step { Step(at: at, .expect(e)) }
        let a = "sim-a", b = "sim-b", c = "sim-c"

        return [
            SimulationScenario(
                id: .normalRun, title: "Normal run",
                summary: "A prompt, the panel after 5 s, and it closes when the agent finishes 10 s later.",
                steps: [
                    prompt(a, 0),
                    expect(1, .scheduled(session: a, fireAt: delay)),
                    expect(delay - 1, .hidden),
                    expect(delay + 1.5, .visible(session: a)),
                    expect(14, .visible(session: a)),
                    stop(a, 15),
                    expect(16.5, .hidden),
                    expect(16.5, .closed(.agentStopped)),
                    expect(16.5, .shows(1)),
                ]),
            SimulationScenario(
                id: .shortRun, title: "Short run (no reminder)",
                summary: "The agent finishes 3 s after the prompt, inside the 5 s delay: nothing is shown.",
                steps: [
                    prompt(a, 0),
                    expect(1, .scheduled(session: a)),
                    stop(a, 3),
                    expect(4, .nothingScheduled),
                    expect(4, .running(session: a, false)),
                    expect(delay + 3, .hidden),
                    expect(delay + 3, .shows(0)),
                ]),
            SimulationScenario(
                id: .escInterrupt, title: "Esc interrupt, no stop",
                summary: "The run is interrupted with Esc, which fires no hook. The untouched panel closes on its own 3 minutes after it appeared.",
                steps: [
                    prompt(a, 0),
                    expect(delay + 1.5, .visible(session: a)),
                    expect(delay + untouched - 2, .visible(session: a)),
                    expect(delay + untouched + 1.5, .hidden),
                    expect(delay + untouched + 1.5, .closed(.untouched)),
                    expect(delay + untouched + 1.5, .running(session: a, true)),
                ]),
            SimulationScenario(
                id: .permissionPause, title: "Permission pause mid-reminder",
                summary: "The panel is up when the agent stops to ask for permission: it closes within 2 s.",
                steps: [
                    prompt(a, 0),
                    expect(delay + 1.5, .visible(session: a)),
                    Step(at: 10, .event(.wait, session: a, t: 10)),
                    expect(11.5, .hidden),
                    expect(11.5, .closed(.agentStopped)),
                    expect(11.5, .running(session: a, false)),
                ]),
            SimulationScenario(
                id: .threeSessions, title: "Three concurrent sessions",
                summary: "Three sessions prompt a second apart and one prompts again while the panel is up: exactly one reminder.",
                steps: [
                    prompt(a, 0), prompt(b, 1), prompt(c, 2),
                    expect(3, .scheduled(session: a, fireAt: delay)),
                    expect(delay + 1.5, .visible(session: a)),
                    prompt(b, 8),
                    expect(9, .shows(1)),
                    stop(b, 10), stop(c, 11),
                    expect(12, .visible(session: a)),
                    stop(a, 14),
                    expect(15.5, .hidden),
                    expect(15.5, .closed(.agentStopped)),
                    // Waiting to settle blocks a new reminder (decision 29).
                    prompt(c, 16),
                    expect(17, .nothingScheduled),
                    expect(delay + 17, .shows(1)),
                ]),
            SimulationScenario(
                id: .handOff, title: "Early stop hands off the check",
                summary: "Session A stops before its check fires while B is running: the check moves to B and the panel is B's.",
                steps: [
                    prompt(a, 0), prompt(b, 2),
                    expect(2.5, .scheduled(session: a, fireAt: delay)),
                    stop(a, 3),
                    expect(4, .scheduled(session: b, fireAt: 2 + delay)),
                    expect(6, .hidden),
                    expect(2 + delay + 1.5, .visible(session: b)),
                    stop(b, 12),
                    expect(13.5, .hidden),
                    expect(13.5, .closed(.agentStopped)),
                    expect(13.5, .shows(1)),
                ]),
            SimulationScenario(
                id: .outOfOrder, title: "Stop lands before its prompt",
                summary: "Async hooks land out of order: the run's stop arrives first, then its older prompt. The session stays not running and nothing is shown.",
                steps: [
                    Step(at: 0, .event(.stop, session: a, t: 1)),
                    Step(at: 0.5, .event(.prompt, session: a, t: 0)),
                    expect(2, .running(session: a, false)),
                    expect(2, .nothingScheduled),
                    expect(delay + 3, .hidden),
                    expect(delay + 3, .shows(0)),
                ]),
        ]
    }()
}
