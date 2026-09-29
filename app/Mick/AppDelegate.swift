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

        let home = MickHome.resolve(environment: environment)
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

        if options.smoke {
            let smoke = SmokeCheck(delegate: self)
            Task { await smoke.run() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceSignals?.stop()
        engine?.stop()
    }

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
