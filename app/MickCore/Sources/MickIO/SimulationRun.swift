import Foundation
import MickCore

/// Simulation mode's file side (SPEC §16, issue #12): a throwaway Mick home under the
/// system temp directory, set up armed with simulation settings, and hook events
/// written into it the way the plugin writes them. It never uses `~/.mick`.
public enum Simulation {
    public enum SetupError: Error, Equatable, CustomStringConvertible {
        /// The home is the real one (`~/.mick`), or not under the temp directory.
        case notATemporaryHome(String)

        public var description: String {
            switch self {
            case .notATemporaryHome(let path): "simulation refuses to use \(path): only a temporary Mick home"
            }
        }
    }

    /// `$TMPDIR` when set (a test script can keep everything in its own scratch
    /// directory; `FileManager.temporaryDirectory` ignores it in an app), else the
    /// user's temporary directory.
    public static var temporaryDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["TMPDIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    /// A new directory `mick-simulate-<id>` under `temporaryDirectory` (mode 0700),
    /// holding one Mick home per run.
    public static func makeRoot(temporaryDirectory: URL = Simulation.temporaryDirectory) throws -> URL {
        let root = temporaryDirectory.appendingPathComponent("mick-simulate-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root.standardizedFileURL
    }

    /// Throws unless `home` is a temporary directory and not the real Mick home.
    public static func checkTemporary(_ home: MickHome,
                                      realHome: MickHome = MickHome.resolve(environment: [:]),
                                      temporaryDirectory: URL = Simulation.temporaryDirectory) throws {
        let path = resolved(home.url)
        let real = resolved(realHome.url)
        let temp = resolved(temporaryDirectory)
        guard path != real, !path.hasPrefix(real + "/"), path.hasPrefix(temp.hasSuffix("/") ? temp : temp + "/") else {
            throw SetupError.notATemporaryHome(home.url.path)
        }
    }

    /// The path with symlinks resolved in its deepest existing ancestor (`/var` is
    /// `/private/var`), so a home that doesn't exist yet compares correctly.
    static func resolved(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        for part in rest { result.appendPathComponent(part) }
        let path = result.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Creates `home` (0700) and writes the simulation config and an armed state.
    public static func prepare(_ home: MickHome, now: Date,
                               temporaryDirectory: URL = Simulation.temporaryDirectory) throws {
        try checkTemporary(home, temporaryDirectory: temporaryDirectory)
        try home.ensureExists()
        try JSONFileStore.save(SimulationScenario.config, to: home.config)
        try JSONFileStore.save(SimulationScenario.initialState(now: now), to: home.state)
    }

    /// One `events.jsonl` line (SPEC §6.2), as the hook writes it.
    public static func eventLine(_ kind: MickEvent.Kind, session: String, time: Date, cwd: String = SimulationScenario.cwd) -> String {
        let object: [String: Any] = ["e": kind.rawValue, "t": time.timeIntervalSince1970, "s": session, "c": cwd, "n": NSNull()]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Appends one line with a single write, creating the file with mode 0600 like the hook.
    public static func append(_ line: String, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
}

/// Plays one `SimulationScenario` against a running `MickEngine`: writes its events to
/// the engine's `events.jsonl` at their times (so they go through the real tailer and
/// ordering) and checks its expectations. The caller drives time: the app calls
/// `performDueSteps` from a timer; tests call it after moving a fake clock.
///
/// Create it after whatever renders the panel has set `engine.onReminder`: the run
/// chains onto that closure to count shows and closes.
@MainActor
public final class SimulationRun {
    public struct Result: Equatable, Sendable {
        public var at: TimeInterval
        public var expectation: SimulationScenario.Expectation
        public var passed: Bool
        /// What was actually there, for a failure.
        public var actual: String
    }

    public let scenario: SimulationScenario
    public let engine: MickEngine
    public let startedAt: Date
    public private(set) var results: [Result] = []
    public private(set) var shows = 0
    public private(set) var lastClose: Reminder.CloseReason?
    /// Whether the panel is on screen. Defaults to the engine's view; the app passes
    /// the real window's visibility.
    public var panelIsVisible: () -> Bool
    /// Called for every step performed (events and checks), for logging.
    public var onStep: ((SimulationScenario.Step, Result?) -> Void)?
    private var next = 0

    public init(scenario: SimulationScenario, engine: MickEngine, startedAt: Date) {
        self.scenario = scenario
        self.engine = engine
        self.startedAt = startedAt
        self.panelIsVisible = { [weak engine] in engine?.reminder.panel != nil }
        let previous = engine.onReminder
        engine.onReminder = { [weak self] effects in
            previous?(effects)
            self?.record(effects)
        }
    }

    public var isFinished: Bool { next >= scenario.steps.count }
    public var passed: Bool { results.allSatisfy(\.passed) }
    public var failures: [Result] { results.filter { !$0.passed } }

    /// When the next step is due, or nil when every step has run.
    public var nextStepAt: Date? {
        isFinished ? nil : startedAt.addingTimeInterval(scenario.steps[next].at)
    }

    /// When the scenario is over.
    public var endsAt: Date { startedAt.addingTimeInterval(scenario.duration) }

    /// Performs every step due at `now`, in order. Returns how many ran.
    @discardableResult
    public func performDueSteps(now: Date) throws -> Int {
        var count = 0
        while !isFinished, startedAt.addingTimeInterval(scenario.steps[next].at) <= now {
            let step = scenario.steps[next]
            next += 1
            count += 1
            switch step.action {
            case .event(let kind, let session, let t):
                let line = Simulation.eventLine(kind, session: session, time: startedAt.addingTimeInterval(t))
                try Simulation.append(line, to: engine.home.events)
                onStep?(step, nil)
            case .expect(let e):
                let result = evaluate(e, at: step.at)
                results.append(result)
                onStep?(step, result)
            }
        }
        return count
    }

    private func record(_ effects: [Reminder.Effect]) {
        for effect in effects {
            switch effect {
            case .show: shows += 1
            case .closed(_, let reason): lastClose = reason
            default: break
            }
        }
    }

    func evaluate(_ e: SimulationScenario.Expectation, at: TimeInterval) -> Result {
        let reminder = engine.reminder
        let visible = panelIsVisible()
        let (ok, actual): (Bool, String) = switch e {
        case .visible(let s):
            (visible && reminder.panel?.sessionID == s, visible ? "panel for \(reminder.panel?.sessionID ?? "none")" : "no panel (\(describe(reminder.phase)))")
        case .hidden:
            (!visible && reminder.panel == nil, visible ? "panel visible" : describe(reminder.phase))
        case .scheduled(let s, let fireAt):
            if let c = reminder.check {
                (c.sessionID == s && fireAt.map { abs(c.fireAt.timeIntervalSince(startedAt) - $0) <= 0.5 } != false,
                 "check for \(c.sessionID) at +\(String(format: "%.1f", c.fireAt.timeIntervalSince(startedAt)))s")
            } else {
                (false, describe(reminder.phase))
            }
        case .nothingScheduled:
            (reminder.check == nil && reminder.panel == nil && !visible, describe(reminder.phase))
        case .closed(let reason):
            (lastClose == reason, "last close \(lastClose?.rawValue ?? "none")")
        case .running(let s, let running):
            ((engine.state.sessions[s]?.running ?? false) == running, "running \(engine.state.sessions[s]?.running ?? false)")
        case .shows(let n):
            (shows == n, "\(shows) shown")
        }
        return Result(at: at, expectation: e, passed: ok, actual: actual)
    }

    private func describe(_ phase: Reminder.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .scheduled(let c): "check for \(c.sessionID)"
        case .visible(let p): "panel for \(p.sessionID ?? "none")"
        case .settling(let s): "settling (\(s.reason.rawValue))"
        }
    }
}

extension SimulationScenario.Expectation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .visible(let s): "panel visible for \(s)"
        case .hidden: "no panel"
        case .scheduled(let s, let at): "check scheduled for \(s)" + (at.map { String(format: " at +%.0fs", $0) } ?? "")
        case .nothingScheduled: "nothing scheduled or visible"
        case .closed(let r): "closed (\(r.rawValue))"
        case .running(let s, let r): "\(s) \(r ? "running" : "not running")"
        case .shows(let n): "\(n) panel(s) shown"
        }
    }
}
