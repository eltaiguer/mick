#if DEBUG
import AppKit
import MickCore
import MickIO

/// Simulation mode (SPEC §16, issue #12), debug builds only. Each scenario run gets
/// its own engine on a fresh temporary Mick home (1-minute thresholds, 5 s delay,
/// already armed) and its own real reminder panel under the status item. Scripted hook
/// events are written into that home's `events.jsonl`, so they go through the real
/// tailer, ordering and reminder logic. The app's own engine and home are never used,
/// so a run can start from the menu of a normal debug launch without touching Mick's
/// real home, and every run starts clean (no settling reminder left from the last).
@MainActor
final class SimulationController {
    private struct Active {
        let scenario: SimulationScenario
        let engine: MickEngine
        let panel: ReminderPanelController
        let run: SimulationRun
    }

    private let statusButton: () -> NSStatusBarButton?
    private let idleSeconds: (@MainActor () -> Double)?
    /// Print every step to stdout (a `--simulate` launch from a terminal).
    private let echo: Bool
    private var root: URL?
    private var active: Active?
    private var queue: [SimulationScenario.ID] = []
    private var timer: Timer?
    private var runCount = 0
    private var failedChecks = 0
    private var passedChecks = 0
    /// Called with true if every check passed, once a started queue is done.
    var onQueueFinished: ((Bool) -> Void)?
    /// The last finished run, for the menu.
    private(set) var lastSummary: String?

    /// - Parameter root: where run homes go; created on the first run when nil.
    init(root: URL?, statusButton: @escaping () -> NSStatusBarButton?,
         idleSeconds: (@MainActor () -> Double)?, echo: Bool) {
        self.root = root
        self.statusButton = statusButton
        self.idleSeconds = idleSeconds
        self.echo = echo
    }

    var isRunning: Bool { active != nil }
    /// The running scenario's panel, for checks.
    var activePanel: ReminderPanelController? { active?.panel }

    // MARK: - Running

    /// Stops whatever is running and plays `ids` in order.
    func start(_ ids: [SimulationScenario.ID]) {
        stop()
        queue = ids
        passedChecks = 0
        failedChecks = 0
        startNext()
    }

    /// Stops the current run and clears the queue.
    func stop() {
        queue = []
        if let active { finish(active, completed: false) }
    }

    private func startNext() {
        guard !queue.isEmpty else {
            if runCount > 0 { onQueueFinished?(failedChecks == 0) }
            return
        }
        let id = queue.removeFirst()
        let scenario = SimulationScenario.named(id)
        do {
            let root = try self.root ?? Simulation.makeRoot()
            self.root = root
            runCount += 1
            let home = MickHome(url: root.appendingPathComponent(String(format: "%02d-%@", runCount, id.rawValue), isDirectory: true))
            try Simulation.prepare(home, now: Date())
            let log = RotatingLog(url: home.log, echoToStderr: false)
            let engine: MickEngine
            if let idleSeconds {
                engine = MickEngine(home: home, log: log, idleSeconds: idleSeconds)
            } else {
                engine = MickEngine(home: home, log: log)
            }
            try engine.start()
            let panel = ReminderPanelController(engine: engine, statusButton: statusButton)
            let run = SimulationRun(scenario: scenario, engine: engine, startedAt: engine.now)
            run.panelIsVisible = { [weak panel] in panel?.isVisible ?? false }
            run.onStep = { [weak self, weak log] step, result in
                let line = Self.describe(step, result, scenario: scenario)
                log?.log("simulation: \(line)")
                if self?.echo == true { print(line) }
            }
            let active = Active(scenario: scenario, engine: engine, panel: panel, run: run)
            self.active = active
            say("SIMULATE \(id.rawValue): \(scenario.title). \(scenario.summary) (home \(home.url.path))")
            engine.log.log("simulation: \(id.rawValue) started")
            advance()
        } catch {
            say("SIMULATE \(id.rawValue) couldn't start: \(error)")
            failedChecks += 1
            startNext()
        }
    }

    /// Runs due steps, then sleeps until the next one (or the end of the scenario).
    private func advance() {
        timer?.invalidate()
        timer = nil
        guard let active else { return }
        let now = Date()
        do {
            try active.run.performDueSteps(now: now)
        } catch {
            say("FAIL [\(active.scenario.id.rawValue)] couldn't write an event: \(error)")
            failedChecks += 1
        }
        guard let wake = active.run.nextStepAt ?? (now < active.run.endsAt ? active.run.endsAt : nil) else {
            finish(active, completed: true)
            return
        }
        // A one-shot Timer with zero tolerance, like the engine's (asyncAfter runs late).
        let timer = Timer(timeInterval: max(0, wake.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func finish(_ finished: Active, completed: Bool) {
        timer?.invalidate()
        timer = nil
        active = nil
        let run = finished.run
        let passed = run.results.filter(\.passed).count
        let failed = run.results.count - passed
        passedChecks += passed
        failedChecks += failed + (completed ? 0 : 1)
        let verdict = completed ? (failed == 0 ? "passed" : "FAILED") : "stopped"
        lastSummary = "\(finished.scenario.title): \(verdict) (\(passed)/\(run.results.count) checks)"
        finished.engine.log.log("simulation: \(finished.scenario.id.rawValue) \(verdict), \(passed)/\(run.results.count) checks")
        say("SIMULATE \(finished.scenario.id.rawValue) \(verdict): \(passed)/\(run.results.count) checks")
        finished.panel.panel.orderOut(nil)
        finished.engine.stop()
        if completed { startNext() }
    }

    private func say(_ line: String) {
        if echo { print(line) }
    }

    private static func describe(_ step: SimulationScenario.Step, _ result: SimulationRun.Result?, scenario: SimulationScenario) -> String {
        let at = String(format: "+%.1fs", step.at)
        switch step.action {
        case .event(let kind, let session, let t):
            return "     [\(scenario.id.rawValue) \(at)] \(kind.rawValue) \(session)" + (t != step.at ? String(format: " (t +%.1fs)", t) : "")
        case .expect(let e):
            guard let result else { return "" }
            return "\(result.passed ? "PASS" : "FAIL") [\(scenario.id.rawValue) \(at)] \(e)" + (result.passed ? "" : ": got \(result.actual)")
        }
    }

    // MARK: - Menu

    /// "Simulate ▸" with one item per scenario, Run all and Stop.
    func menuItems() -> [NSMenuItem] {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if let active {
            submenu.addItem(disabled("Running: \(active.scenario.title)"))
        } else if let lastSummary {
            submenu.addItem(disabled("Last: \(lastSummary)"))
        }
        if submenu.numberOfItems > 0 { submenu.addItem(.separator()) }
        for scenario in SimulationScenario.all {
            let item = NSMenuItem(title: scenario.title, action: #selector(MenuTarget.play(_:)), keyEquivalent: "")
            item.target = menuTarget
            item.representedObject = scenario.id.rawValue
            item.toolTip = scenario.summary
            item.state = active?.scenario.id == scenario.id ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let all = NSMenuItem(title: "Run all", action: #selector(MenuTarget.playAll), keyEquivalent: "")
        all.target = menuTarget
        submenu.addItem(all)
        let stop = NSMenuItem(title: "Stop simulation", action: #selector(MenuTarget.stop), keyEquivalent: "")
        stop.target = menuTarget
        stop.isEnabled = active != nil
        submenu.addItem(stop)
        submenu.addItem(.separator())
        submenu.addItem(disabled("Temporary home, 1-min thresholds, 5 s delay"))
        if let root { submenu.addItem(disabled(root.path)) }

        let item = NSMenuItem(title: "Simulate (debug)", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return [item]
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private lazy var menuTarget = MenuTarget(owner: self)

    /// NSMenuItem targets must be NSObjects.
    @MainActor
    final class MenuTarget: NSObject {
        unowned let owner: SimulationController
        init(owner: SimulationController) { self.owner = owner }

        @objc func play(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let id = SimulationScenario.ID(rawValue: raw) else { return }
            owner.start([id])
        }
        @objc func playAll() { owner.start(SimulationScenario.ID.allCases) }
        @objc func stop() { owner.stop() }
    }
}
#endif
