import AppKit
import PanelSpikeKit

@MainActor
final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    let options: SpikeOptions
    private var statusItem: NSStatusItem?
    private var controller: PanelController!
    private var cycleTimer: Timer?
    private var logHandle: FileHandle?
    private let levelMenu = NSMenu()

    init(options: SpikeOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The built .app sets LSUIElement; this also covers `swift run`.
        NSApp.setActivationPolicy(options.regular ? .regular : .accessory)
        if let path = options.logPath {
            FileManager.default.createFile(atPath: path, contents: nil)
            logHandle = FileHandle(forWritingAtPath: path)
            logHandle?.seekToEndOfFile()
        }

        controller = PanelController(level: options.level)
        controller.model.onInteraction = { [weak self] what in
            guard let self else { return }
            self.log("click \(what): \(self.controller.snapshot())")
        }

        if options.preferRight {
            // Registration domain only (not persisted): ask for a slot near the right
            // edge so the anchored path can be exercised on a crowded notched menu bar.
            UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position PanelSpike": 120])
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if options.preferRight { item.autosaveName = "PanelSpike" }
        item.button?.image = NSImage(systemSymbolName: "figure.boxing", accessibilityDescription: "Panel spike")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: "Panel spike")
        item.menu = buildMenu()
        statusItem = item
        controller.statusButton = item.button

        log("launch policy=\(options.regular ? "regular" : "accessory") level=\(options.level.rawValue) pid=\(ProcessInfo.processInfo.processIdentifier)")

        if options.smoke {
            // Let the status item get its window on screen first.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                await self.runSmoke()
            }
            return
        }
        if let delay = options.showAfter {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                self.showPanel()
            }
        }
        if let every = options.cycle { startCycle(every: every) }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show panel now", action: #selector(showNow), keyEquivalent: "")
        menu.addItem(withTitle: "Show panel in 5 s", action: #selector(showIn5), keyEquivalent: "")
        menu.addItem(withTitle: "Toggle panel every 5 s", action: #selector(toggleCycle), keyEquivalent: "")
        menu.addItem(withTitle: "Hide panel", action: #selector(hideNow), keyEquivalent: "")
        menu.addItem(.separator())
        for level in PanelLevel.allCases {
            let mi = NSMenuItem(title: "Level: \(level.rawValue)", action: #selector(pickLevel(_:)), keyEquivalent: "")
            mi.representedObject = level.rawValue
            mi.state = level == options.level ? .on : .off
            menu.addItem(mi)
        }
        let policy = NSMenuItem(title: "Policy: \(options.regular ? "regular" : "accessory") (relaunch with --regular to change)", action: nil, keyEquivalent: "")
        policy.isEnabled = false
        menu.addItem(policy)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit panel spike", action: #selector(quit), keyEquivalent: "q")
        for mi in menu.items where mi.action != nil { mi.target = self }
        return menu
    }

    @objc private func showNow() { showPanel() }
    @objc private func hideNow() { cycleTimer?.invalidate(); cycleTimer = nil; controller.hide(); log("hide") }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showIn5() {
        log("show scheduled in 5 s; switch to the app you're typing in")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            self.showPanel()
        }
    }

    @objc private func toggleCycle() {
        if cycleTimer != nil {
            cycleTimer?.invalidate(); cycleTimer = nil
            log("cycle off")
        } else {
            startCycle(every: 5)
        }
    }

    @objc private func pickLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let level = PanelLevel(rawValue: raw) else { return }
        controller.panel.setLevel(level)
        sender.menu?.items.forEach { if $0.action == #selector(pickLevel(_:)) { $0.state = $0 === sender ? .on : .off } }
        log("level -> \(level.rawValue) (window level \(controller.panel.level.rawValue))")
    }

    private func startCycle(every seconds: Double) {
        log("cycle on, every \(seconds) s")
        cycleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
            MainActor.assumeIsolated {
                if self.controller.panel.isVisible { self.controller.hide(); self.log("cycle hide") } else { self.showPanel() }
            }
        }
    }

    // MARK: Show + probe

    private func showPanel() {
        let before = controller.snapshot()
        let anchor = controller.statusItemAnchor()
        controller.show()
        log("show before: \(before)")
        log("status item: \(controller.statusItemDiagnostics())")
        log("show anchor=\(anchor.map { "\($0)" } ?? "nil (fallback top-right)") frame=\(controller.panel.frame) level=\(controller.panel.level.rawValue)")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            let after = self.controller.snapshot()
            let ok = after.frontmostPID == before.frontmostPID && !after.panelIsKey && !after.appIsActive
            self.log("show after:  \(after) \(ok ? "OK" : "FOCUS CHANGED")")
        }
    }

    private func log(_ line: String) {
        let stamped = "\(Date().formatted(.iso8601)) \(line)\n"
        FileHandle.standardError.write(Data(stamped.utf8))
        logHandle?.write(Data(stamped.utf8))
    }

    // MARK: Smoke

    private func runSmoke() async {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print("\(ok ? "PASS" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        let before = controller.snapshot()
        let anchor = controller.statusItemAnchor()
        controller.show()
        try? await Task.sleep(for: .milliseconds(500))
        let after = controller.snapshot()
        print("before: \(before)")
        print("after:  \(after)")
        print("status item: \(controller.statusItemDiagnostics())")
        print("screens: \(NSScreen.screens.map { "\($0.frame) visible \($0.visibleFrame)" })")
        print("anchor: \(anchor.map { "\($0)" } ?? "nil")  frame: \(controller.panel.frame)")

        check(after.panelIsVisible, "panel visible after orderFrontRegardless")
        check(!after.panelIsKey, "panel is not key")
        check(!after.appIsActive, "app not activated")
        check(after.frontmostPID == before.frontmostPID, "frontmost app unchanged")
        let frame = controller.panel.frame
        check(NSScreen.screens.contains { $0.visibleFrame.contains(frame) }, "panel inside a screen's visible frame")
        if let anchor, PanelPlacement.screenIndex(forAnchor: anchor, in: NSScreen.screens.map(ScreenGeometry.init(screen:))) != nil {
            check(abs(frame.maxY - (anchor.minY - PanelPlacement.gap)) <= 1, "panel top edge just below the status item (window frames snap to whole points)")
            check(abs(frame.midX - anchor.midX) <= 1, "panel centered on the status item")
        } else {
            print("INFO status item anchor unusable; top-right fallback used")
        }

        controller.syntheticClick(control: SpikeModel.toggleID(0))
        controller.syntheticClick(control: SpikeModel.notNowID)
        try? await Task.sleep(for: .milliseconds(200))
        let clicked = controller.snapshot()
        check(controller.model.checked[0], "single click ticked the checkbox")
        check(controller.model.notNowTaps == 1, "single click triggered the plain button")
        check(!clicked.panelIsKey && !clicked.appIsActive, "still not key or active after clicks")
        check(clicked.frontmostPID == before.frontmostPID, "frontmost app unchanged after clicks")

        controller.hide()
        print(failures.isEmpty ? "SMOKE OK" : "SMOKE FAILED: \(failures.count)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
