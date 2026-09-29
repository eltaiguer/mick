import AppKit
import MickCore
import MickIO

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    private(set) var engine: MickEngine!
    private(set) var statusItem: StatusItemController!
    private(set) var onboarding: OnboardingWindowController!
    private(set) var workspaceSignals: WorkspaceSignals!
    private(set) var reminderPanel: ReminderPanelController!
#if DEBUG
    private(set) var simulation: SimulationController?
#endif

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement; this also covers running the bare binary.
        NSApp.setActivationPolicy(.accessory)

        let environment = ProcessInfo.processInfo.environment
        if options.smoke, (environment["MICK_HOME"] ?? "").isEmpty {
            FileHandle.standardError.write(Data("Mick: --smoke needs MICK_HOME set to a temporary directory\n".utf8))
            exit(2)
        }

        var home = MickHome.resolve(environment: environment)
#if DEBUG
        // Simulation mode never touches Mick's real home (or MICK_HOME): the app's own
        // engine gets a fresh temporary one too, armed and with the hooks known, so no
        // onboarding pops up. Scenario runs get their own homes next to it.
        var simulationRoot: URL?
        if options.simulate != nil {
            do {
                let root = try Simulation.makeRoot()
                simulationRoot = root
                home = MickHome(url: root.appendingPathComponent("app", isDirectory: true))
                try Simulation.prepare(home, now: Date())
                print("SIMULATION root \(root.path)")
            } catch {
                fail("Mick can't set up a simulation home: \(error)")
                return
            }
        }
#endif
        let log = RotatingLog(url: home.log, echoToStderr: options.smoke)
        let engine: MickEngine
        if options.smoke, let idle = options.smokeIdle {
            engine = MickEngine(home: home, log: log, idleSeconds: { idle })
        } else {
            engine = MickEngine(home: home, log: log)
        }
        self.engine = engine
        do {
            try engine.start()
        } catch {
            fail("Mick can't create its folder at \(home.url.path): \(error.localizedDescription)")
            return
        }

        workspaceSignals = WorkspaceSignals(engine: engine)
        onboarding = OnboardingWindowController(engine: engine)
        statusItem = StatusItemController(engine: engine) { [weak self] in
            self?.onboarding.show(activate: true)
        }
        reminderPanel = ReminderPanelController(engine: engine) { [weak self] in self?.statusItem.item.button }

        // First launch, or the hooks were never seen: explain how to set up. An
        // LSUIElement app isn't activated when opened from Finder, so bring onboarding
        // forward on a real first launch (the person just opened Mick). Later launches,
        // such as the login item, show it without taking focus. The smoke check never
        // activates, so unattended runs don't pull focus.
        if !engine.hooks.everDetected {
            onboarding.show(activate: engine.createdHome && !options.smoke)
        }

#if DEBUG
        var simulatedIdle: (@MainActor () -> Double)?
        if let idle = options.simulateIdle { simulatedIdle = { idle } }
        let simulation = SimulationController(
            root: simulationRoot,
            statusButton: { [weak self] in self?.statusItem.item.button },
            idleSeconds: simulatedIdle,
            echo: options.simulate != nil
        )
        self.simulation = simulation
        statusItem.extraMenuItems = { [weak simulation] in simulation?.menuItems() ?? [] }
        if case .scenarios(let ids)? = options.simulate {
            if options.simulateExit {
                simulation.onQueueFinished = { (passed: Bool) in
                    print(passed ? "SIMULATION OK" : "SIMULATION FAILED")
                    exit(passed ? 0 : 1)
                }
            }
            // Let the status item settle so the panel anchors under it.
            let viaMenu = options.simulateViaMenu
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    if viaMenu { self.chooseFromSimulateMenu(ids[0]) } else { simulation.start(ids) }
                }
            }
        }
#endif

        if options.smoke {
            let smoke = SmokeCheck(delegate: self)
            Task { await smoke.run() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
#if DEBUG
        simulation?.stop()
#endif
        workspaceSignals?.stop()
        engine?.stop()
    }

#if DEBUG
    /// Picks `id` in the status item's Simulate submenu, as a click would.
    private func chooseFromSimulateMenu(_ id: SimulationScenario.ID) {
        guard let menu = statusItem.item.menu else { return }
        statusItem.menuNeedsUpdate(menu)
        guard let submenu = menu.items.first(where: { $0.title == "Simulate (debug)" })?.submenu,
              let index = submenu.items.firstIndex(where: { $0.representedObject as? String == id.rawValue }) else {
            print("FAIL the Simulate menu has no \(id.rawValue) item")
            print("SIMULATION FAILED")
            exit(1)
        }
        print("PASS chose \"\(submenu.items[index].title)\" in the Simulate menu")
        submenu.performActionForItem(at: index)
    }
#endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func fail(_ message: String) {
        FileHandle.standardError.write(Data("Mick: \(message)\n".utf8))
        if options.smoke { exit(1) }
        let alert = NSAlert()
        alert.messageText = "Mick couldn't start"
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
        NSApp.terminate(nil)
    }
}
