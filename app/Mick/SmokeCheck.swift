import AppKit
import MickCore
import MickIO

/// `--smoke`: an unattended end-to-end check of the shell, run inside the real app
/// against a temporary `MICK_HOME` (tests/app/smoke.sh drives it). Prints one
/// PASS/FAIL line per check, then quits with 0 or 1.
@MainActor
final class SmokeCheck {
    private unowned let delegate: AppDelegate
    private var failures: [String] = []

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    private func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL") \(what)")
        if !ok { failures.append(what) }
    }

    func run() async {
        try? await Task.sleep(for: .milliseconds(700))  // let the status item and window settle
        let engine = delegate.engine!
        let statusItem = delegate.statusItem!
        let home = engine.home

        // Menu bar agent: accessory policy, LSUIElement, own status item and menu.
        check(NSApp.activationPolicy() == .accessory, "activation policy is accessory (no Dock icon)")
        check(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true, "Info.plist sets LSUIElement")
        check(NSRunningApplication.current.activationPolicy == .accessory, "running application reports accessory")
        check(statusItem.item.button?.image != nil, "status item has an icon")
        check(statusItem.item.menu != nil, "status item has its own menu")
        check(statusItem.item.menu?.items.last?.title == "Quit Mick", "menu ends with Quit Mick")

        // Home directory and files.
        let mode = (try? FileManager.default.attributesOfItem(atPath: home.url.path))?[.posixPermissions] as? Int
        check(mode == 0o700, "MICK_HOME exists with mode 0700 (got \(mode.map { String($0, radix: 8) } ?? "none"))")
        check(FileManager.default.fileExists(atPath: home.config.path), "config.json written")
        check(FileManager.default.fileExists(atPath: home.state.path), "state.json written")
        check(FileManager.default.fileExists(atPath: home.log.path), "log.txt written")
        print("INFO createdHome=\(engine.createdHome) config=\(engine.configOutcome) state=\(engine.stateOutcome) hooks=\(engine.hooks)")

        guard let hook = delegate.options.smokeHook else {
            finish()
            return
        }

        // Warning state until the hooks are detected.
        check(engine.hooks == .notDetected, "hooks not detected before the first event")
        check(statusItem.icon == .warning, "warning icon before the first event")
        check(statusItem.topLine == "Claude Code hooks not detected. Set up…", "menu shows the hooks-not-detected line")
        check(delegate.onboarding.isVisible, "onboarding shown on first launch")
        check(OnboardingStatus(engine.hooks) == .waiting, "onboarding says it's waiting for the first prompt")

        // A real hook event, written by the plugin's script.
        let clock = ContinuousClock()
        let started = clock.now
        let status = runHook(path: hook, home: home)
        check(status == 0, "hook script exited 0")
        let deadline = started + .seconds(2)
        while clock.now < deadline, !(engine.hooks.everDetected && statusItem.icon == .calm) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = clock.now - started
        check(engine.hooks.everDetected, "hooks detected after the first event")
        check(OnboardingStatus(engine.hooks) == .connected, "onboarding shows the check mark")
        check(statusItem.icon == .calm, "warning icon cleared")
        check(statusItem.topLine != "Claude Code hooks not detected. Set up…", "hooks-not-detected line cleared")
        check(elapsed < .seconds(2), "detected within 2 s (took \(elapsed.formatted(.units(allowed: [.milliseconds]))))")
        check(engine.state.sessions["smoke-session"]?.running == true, "session marked running")

        // Persisted for the next launch.
        let saved = JSONFileStore.load(MickState.self, from: home.state, defaults: .defaults(now: Date()), now: Date(), log: MemoryLog()).value
        check(saved.lastEventAt != nil, "last_event_at saved to state.json")
        finish()
    }

    private func runHook(path: String, home: MickHome) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["prompt"]
        process.environment = ["MICK_HOME": home.url.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        process.standardInput = stdin
        do {
            try process.run()
        } catch {
            print("FAIL couldn't run the hook: \(error.localizedDescription)")
            return -1
        }
        let payload = #"{"session_id":"smoke-session","cwd":"/tmp/mick-smoke","hook_event_name":"UserPromptSubmit","prompt":"SMOKE-SECRET"}"#
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func finish() {
        print(failures.isEmpty ? "SMOKE OK" : "SMOKE FAILED: \(failures.count)")
        delegate.engine.stop()
        exit(failures.isEmpty ? 0 : 1)
    }
}
