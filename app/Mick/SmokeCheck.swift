import AppKit
import MickCore
import MickIO
import ServiceManagement

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
        let items = statusItem.item.menu?.items ?? []
        check(items.count >= 2 && items[items.count - 2].title == StatusItemController.settingsTitle, "Settings… right above Quit Mick")
        check(delegate.bell.isLoaded, "the bell sound loads")

        // Home directory and files.
        let mode = (try? FileManager.default.attributesOfItem(atPath: home.url.path))?[.posixPermissions] as? Int
        check(mode == 0o700, "MICK_HOME exists with mode 0700 (got \(mode.map { String($0, radix: 8) } ?? "none"))")
        check(FileManager.default.fileExists(atPath: home.config.path), "config.json written")
        check(FileManager.default.fileExists(atPath: home.state.path), "state.json written")
        check(FileManager.default.fileExists(atPath: home.log.path), "log.txt written")
        print("INFO createdHome=\(engine.createdHome) config=\(engine.configOutcome) state=\(engine.stateOutcome) hooks=\(engine.hooks)")

        // Sitting timer (#5): polled, recorded, shown, and the icon states drawn.
        check(delegate.workspaceSignals.observerCount == 4, "observing sleep/wake and user-switch messages")
        check(statusItem.detailLine?.hasPrefix("Sitting ") == true, "menu shows the sitting detail line (\(statusItem.detailLine ?? "none"))")
        let images = MenuBarIcon.allCases.map { GloveIcon.image(for: $0).tiffRepresentation }
        check(!images.contains(nil) && Set(images.compactMap { $0 }).count == MenuBarIcon.allCases.count,
              "calm, armed, glaring, snoozed, paused and warning icons are drawn and distinct")

        // Dropdown (#10): Stretch now, Snooze ▸ four options, Pause.
        let titles = statusItem.item.menu?.items.map(\.title) ?? []
        check(titles.contains(StatusItemController.stretchNowTitle), "menu has Stretch now")
        let snoozeOptions = statusItem.menuItem(StatusItemController.snoozeTitle)?.submenu?.items.map(\.title) ?? []
        check(snoozeOptions == ["30 minutes", "1 hour", "2 hours", "Until tomorrow (06:00)"], "Snooze submenu offers 30 minutes / 1 hour / 2 hours / Until tomorrow (\(snoozeOptions))")
        check(titles.contains(engine.isPaused ? StatusItemController.resumeTitle : StatusItemController.pauseTitle), "menu has Pause (or Resume when paused)")
        let savedState = JSONFileStore.load(MickState.self, from: home.state, defaults: .defaults(now: .distantPast), now: Date(), log: MemoryLog()).value
        check(abs(savedState.lastActiveAt.timeIntervalSince(engine.state.lastActiveAt)) < 0.001, "last_active_at written to state.json")
        print("INFO icon=\(statusItem.icon.map(\.rawValue) ?? "none") detail=\(statusItem.detailLine ?? "none") sitting_since=\(MickDate.string(from: engine.state.sittingSince))")

        switch delegate.options.smokeSettings {
        case .settings?:
            await runSettings()
            finish()
            return
        case .uninstall?:
            await runUninstall()
            return  // quits through the uninstalled window, like the real thing
        case nil:
            break
        }

        guard let hook = delegate.options.smokeHook else {
            finish()
            return
        }
        if let scenario = delegate.options.smokeReminder {
            await runReminder(scenario, hook: hook)
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
        let status = runHook(path: hook, home: home, kind: "prompt", session: "smoke-session")
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
        let sitting = Int(SittingTimer.sittingSeconds(engine.state, now: engine.now) / 60)
        let calm = engine.lines?.lines(.statusCalm).flatMap { line in
            [sitting - 1, sitting, sitting + 1].map { SpokenTime.render(line.text, sittingMinutes: $0) }
        } ?? []
        check(calm.contains(statusItem.topLine ?? ""), "status line from status_calm (\(statusItem.topLine ?? "none"))")
        check(engine.state.rotation.usedLineIDs["onboarding"]?.count == 1, "onboarding line from the onboarding pool")
        check(elapsed < .seconds(2), "detected within 2 s (took \(elapsed.formatted(.units(allowed: [.milliseconds]))))")
        check(engine.state.sessions["smoke-session"]?.running == true, "session marked running")

        // Persisted for the next launch.
        let saved = JSONFileStore.load(MickState.self, from: home.state, defaults: .defaults(now: Date()), now: Date(), log: MemoryLog()).value
        check(saved.lastEventAt != nil, "last_event_at saved to state.json")
        finish()
    }

    // MARK: - Reminder scenarios (#6)

    /// Expects an armed state (sitting past the threshold, hooks known) and a short show
    /// delay in `MICK_HOME`, and a fixed idle reading of at least 3 s (`--smoke-idle`).
    private func runReminder(_ scenario: LaunchOptions.SmokeReminder, hook: String) async {
        let engine = delegate.engine!
        let panel = delegate.reminderPanel!
        let home = engine.home
        let delay = Double(engine.config.showDelaySeconds)
        let session = "smoke-reminder"
        let me = NSRunningApplication.current.processIdentifier
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        print("INFO scenario=\(scenario.rawValue) delay=\(delay)s frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")

        check(engine.icon == .armed || engine.icon == .glaring, "armed before the prompt (icon \(engine.icon.rawValue))")
        check(engine.reminder.phase == .idle, "no reminder before the prompt")
        check(!engine.isHoldingActivity, "no activity held while nothing is running")

        switch scenario {
        case .stretchNow:
            await runStretchNow(hook: hook, frontBefore: frontBefore, me: me)
            return
        case .menuControls:
            await runMenuControls(hook: hook)
            return
        default:
            break
        }

        let clock = ContinuousClock()
        let prompted = clock.now
        check(runHook(path: hook, home: home, kind: "prompt", session: session) == 0, "prompt hook exited 0")
        await waitFor(.seconds(2)) { engine.state.sessions[session]?.running == true }
        check(engine.reminder.check?.sessionID == session, "check scheduled for the session")
        check(engine.isHoldingActivity, "activity held while a session runs and a check is scheduled")

        if scenario == .shortRun {
            check(runHook(path: hook, home: home, kind: "stop", session: session) == 0, "stop hook exited 0")
            await waitFor(.seconds(2)) { engine.state.sessions[session]?.running == false }
            check(engine.reminder.phase == .idle, "stop within the show delay cancels the check")
            try? await Task.sleep(for: .seconds(delay + 2))
            check(panel.showCount == 0 && !panel.isVisible, "a run shorter than the show delay shows nothing")
            check(!engine.isHoldingActivity, "activity released once nothing is running or scheduled")
            return
        }

        await waitFor(.seconds(delay + 4)) { panel.isVisible }
        let shownAfter = clock.now - prompted
        check(panel.isVisible, "panel shown after the show delay (\(seconds(shownAfter)))")
        check(shownAfter >= .seconds(delay - 0.1), "not shown before the show delay")
        checkPanel(panel, frontBefore: frontBefore, me: me)

        switch scenario {
        case .showStop:
            let stopped = clock.now
            check(runHook(path: hook, home: home, kind: "stop", session: session) == 0, "stop hook exited 0")
            await waitFor(.seconds(2)) { !panel.isVisible }
            let took = clock.now - stopped
            check(!panel.isVisible && took < .seconds(2), "untouched panel closed within 2 s of the stop (took \(seconds(took)))")
            check(engine.reminder.settling?.reason == .agentStopped, "closed because the agent stopped")
            check(engine.isHoldingActivity, "activity still held while the reminder settles")
            check(frontmostUnchanged(frontBefore, me: me), "frontmost app unchanged after close")

        case .panelSnooze:
            let sitting = engine.state.sittingSince
            await waitFor(.seconds(1)) { panel.model.controlFrames[ReminderPanelModel.snoozeID] != nil }
            try? await Task.sleep(for: .milliseconds(300))
            check(panel.syntheticClick(control: ReminderPanelModel.snoozeID), "clicked Snooze ▾")
            let hourID = ReminderPanelModel.snoozeOptionID(.oneHour)
            await waitFor(.seconds(1)) { panel.model.controlFrames[hourID] != nil }
            try? await Task.sleep(for: .milliseconds(300))
            check(panel.model.snoozeOpen, "Snooze ▾ opened the three durations")
            check(!panel.panel.isKeyWindow && !NSApp.isActive && frontmostUnchanged(frontBefore, me: me), "opening Snooze didn't take focus")
            let clickedAt = Date()
            check(panel.syntheticClick(control: hourID), "clicked 1 hour")
            await waitFor(.seconds(1)) { !panel.isVisible }
            check(!panel.isVisible, "snooze closed the panel")
            check(engine.reminder.phase == .idle, "snooze settled at once (nothing left settling)")
            check(engine.lastSettlement?.outcome == .snoozed, "settled as Snoozed (\(engine.lastSettlement?.outcome.rawValue ?? "none"))")
            let until = engine.state.snoozedUntil ?? .distantPast
            check(abs(until.timeIntervalSince(clickedAt) - 3600) < 5, "snoozed for an hour (until \(MickDate.string(from: until)))")
            check(engine.state.sittingSince == sitting, "snooze didn't reset the sitting timer")
            check(engine.state.nagAfter == nil && engine.state.today.ignored == 0, "no penalty")
            await checkIcon(.snoozed)
            await checkStatusLine(from: .snooze, "Mick's snooze line in the status line")
            let log = (try? String(contentsOf: home.reminders, encoding: .utf8)) ?? ""
            check(log.contains(#""outcome":"snoozed""#) && log.contains(#""manual":false"#), "reminders.jsonl records the snooze")
            check(frontmostUnchanged(frontBefore, me: me), "frontmost app unchanged after snoozing")

        case .tickStays:
            // Let SwiftUI report the laid-out control frames (nobody clicks in 0 ms).
            await waitFor(.seconds(1)) { panel.model.controlFrames.count >= 5 }
            try? await Task.sleep(for: .milliseconds(300))
            check(panel.syntheticClick(control: ReminderPanelModel.toggleID(0)), "clicked the first checkbox")
            await waitFor(.seconds(1)) { engine.reminder.panel?.ticked == [0] }
            check(engine.reminder.panel?.ticked == [0], "one click ticked Stand up")
            check(panel.model.ticked == [0], "panel shows the tick")
            check(!panel.panel.isKeyWindow && !NSApp.isActive, "click didn't make the panel key or activate Mick")
            check(frontmostUnchanged(frontBefore, me: me), "frontmost app unchanged after the click")
            check(runHook(path: hook, home: home, kind: "stop", session: session) == 0, "stop hook exited 0")
            await waitFor(.seconds(2)) { engine.state.sessions[session]?.running == false }
            try? await Task.sleep(for: .milliseconds(2500))
            check(panel.isVisible, "with a tick, the panel stays after the agent stops")
            check(panel.syntheticClick(control: ReminderPanelModel.notNowID), "clicked Not now")
            // Closing with some ticked shows the partial done line first (§10.2).
            await waitFor(.seconds(1)) { panel.model.done }
            let partial = engine.reminder.panel?.content.partialLine
            check(panel.isVisible && panel.model.headline == partial && partial != nil,
                  "closing with a tick shows the done_partial line (\(panel.model.headline))")
            check(engine.lines.map { $0.lines(.donePartial).map(\.text).contains(partial ?? "") } == true, "that line comes from done_partial")
            check(engine.state.rotation.usedLineIDs["done_partial"]?.count == 1, "done_partial line recorded in the rotation")
            await waitFor(.seconds(5)) { !panel.isVisible }
            check(!panel.isVisible, "Not now closed the panel after the done line")
            check(engine.reminder.settling?.reason == .notNow, "closed by Not now, now settling")

        case .shortRun, .stretchNow, .menuControls:
            break
        }
    }

    private func statusItem() -> StatusItemController { delegate.statusItem! }

    /// The status item re-renders on the next main-queue turn after the engine
    /// changes; waits for its status line to read `line`.
    /// The status line shows a line from `pool` in the bundled `lines.json`.
    private func checkStatusLine(from pool: LinePool, _ what: String) async {
        let pooled = Set(((try? LineCatalog.bundled())?.lines(pool) ?? []).map(\.text))
        func shown() -> Bool { statusItem().topLine.map(pooled.contains) ?? false }
        await waitFor(.seconds(1)) { shown() }
        check(!pooled.isEmpty && shown(), "\(what) (\(statusItem().topLine ?? "none"))")
    }

    private func checkIcon(_ icon: MenuBarIcon) async {
        await waitFor(.seconds(1)) { statusItem().icon == icon }
        check(engine().icon == icon && statusItem().icon == icon, "\(icon.rawValue) icon (\(statusItem().icon?.rawValue ?? "none"))")
    }

    private func engine() -> MickEngine { delegate.engine! }

    // MARK: - Snooze, pause, Stretch now (#10)

    private func runStretchNow(hook: String, frontBefore: pid_t?, me: pid_t) async {
        let engine = delegate.engine!
        let panel = delegate.reminderPanel!
        let home = engine.home
        let sitting = engine.state.sittingSince
        guard let item = statusItem().menuItem(StatusItemController.stretchNowTitle) else {
            check(false, "menu has Stretch now")
            return
        }
        check(item.isEnabled, "Stretch now enabled with no reminder live")
        check(statusItem().choose(item), "chose Stretch now")
        await waitFor(.seconds(1)) { panel.isVisible }
        check(panel.isVisible, "Stretch now shows the panel at once")
        check(engine.reminder.panel?.isManual == true, "the panel has no session attached")
        checkPanel(panel, frontBefore: frontBefore, me: me)
        check(statusItem().menuItem(StatusItemController.stretchNowTitle)?.isEnabled == false, "Stretch now disabled while its panel is visible")

        // Agent runs start and stop; the manual panel stays.
        check(runHook(path: hook, home: home, kind: "prompt", session: "smoke-other") == 0, "prompt hook exited 0")
        await waitFor(.seconds(2)) { engine.state.sessions["smoke-other"]?.running == true }
        check(engine.reminder.check == nil, "a prompt doesn't schedule a check while Stretch now is up")
        check(runHook(path: hook, home: home, kind: "stop", session: "smoke-other") == 0, "stop hook exited 0")
        await waitFor(.seconds(2)) { engine.state.sessions["smoke-other"]?.running == false }
        try? await Task.sleep(for: .milliseconds(2500))
        check(panel.isVisible, "agent stops don't close Stretch now")

        await waitFor(.seconds(1)) { panel.model.controlFrames[ReminderPanelModel.notNowID] != nil }
        try? await Task.sleep(for: .milliseconds(300))
        check(panel.syntheticClick(control: ReminderPanelModel.notNowID), "clicked Not now")
        await waitFor(.seconds(1)) { !panel.isVisible }
        check(!panel.isVisible, "closing Stretch now hides the panel")
        check(engine.reminder.settling?.panel.isManual == true, "the manual reminder is settling")
        check(statusItem().menuItem(StatusItemController.stretchNowTitle)?.isEnabled == false, "Stretch now disabled while settling")
        check(engine.state.sittingSince == sitting, "sitting timer untouched until it settles")
        check(frontmostUnchanged(frontBefore, me: me), "frontmost app unchanged after Stretch now")
    }

    private func runMenuControls(hook: String) async {
        let engine = delegate.engine!
        let home = engine.home
        let sitting = engine.state.sittingSince
        func saved() -> MickState {
            JSONFileStore.load(MickState.self, from: home.state, defaults: .defaults(now: .distantPast), now: Date(), log: MemoryLog()).value
        }
        func choose(_ title: String) -> Bool {
            guard let item = statusItem().menuItem(title) else { return false }
            return statusItem().choose(item)
        }

        // Pause.
        check(choose(StatusItemController.pauseTitle), "chose Pause")
        check(engine.isPaused && saved().paused, "paused, and saved to state.json")
        await checkIcon(.paused)
        await checkStatusLine(from: .pause, "Mick's pause line in the status line")
        check(statusItem().menuItem(StatusItemController.resumeTitle) != nil, "menu offers Resume while paused")
        check(runHook(path: hook, home: home, kind: "prompt", session: "smoke-paused") == 0, "prompt hook exited 0")
        await waitFor(.seconds(2)) { engine.state.sessions["smoke-paused"]?.running == true }
        check(engine.reminder.phase == .idle, "a prompt while paused schedules nothing")
        check(runHook(path: hook, home: home, kind: "stop", session: "smoke-paused") == 0, "stop hook exited 0")

        // Resume.
        check(choose(StatusItemController.resumeTitle), "chose Resume")
        check(!engine.isPaused && !saved().paused, "resumed, and saved")
        await checkStatusLine(from: .resume, "Mick's resume line in the status line")

        // Snooze from the menu.
        let snoozeMenu = statusItem().menuItem(StatusItemController.snoozeTitle)?.submenu
        let hour = snoozeMenu?.items.first { $0.title == SnoozeOption.oneHour.label }
        let chosenAt = Date()
        check(hour.map { statusItem().choose($0) } ?? false, "chose Snooze ▸ 1 hour")
        let until = engine.state.snoozedUntil ?? .distantPast
        check(abs(until.timeIntervalSince(chosenAt) - 3600) < 5, "snoozed for an hour")
        await checkIcon(.snoozed)
        await checkStatusLine(from: .snooze, "Mick's snooze line in the status line")
        let cancel = statusItem().menuItem(StatusItemController.snoozeTitle)?.submenu?.items.first { $0.title == StatusItemController.cancelSnoozeTitle }
        check(cancel.map { statusItem().choose($0) } ?? false, "chose Cancel snooze")
        check(engine.state.snoozedUntil == nil, "snooze cancelled")

        check(engine.state.sittingSince == sitting && saved().sittingSince == sitting, "snooze, pause and resume never reset the sitting timer")

        // End paused so the next launch can check it persisted.
        check(choose(StatusItemController.pauseTitle), "paused again for the relaunch check")
    }

    private func checkPanel(_ controller: ReminderPanelController, frontBefore: pid_t?, me: pid_t) {
        let panel = controller.panel
        check(!panel.isKeyWindow, "panel is not key")
        check(!panel.canBecomeKey && !panel.canBecomeMain, "panel can't become key or main")
        check(!NSApp.isActive, "showing the panel didn't activate Mick")
        check(NSApp.keyWindow == nil, "Mick has no key window")
        check(frontmostUnchanged(frontBefore, me: me), "frontmost app unchanged (\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"))")
        check(panel.styleMask.contains(.nonactivatingPanel) && panel.styleMask.contains(.borderless), "borderless non-activating panel")
        check(panel.collectionBehavior == ReminderPanel.collectionBehavior && !panel.collectionBehavior.contains(.moveToActiveSpace), "collection behavior as in §9.3")
        check(panel.level == .statusBar, "status bar window level")
        check(!panel.hidesOnDeactivate && panel.becomesKeyOnlyIfNeeded, "hidesOnDeactivate off, becomesKeyOnlyIfNeeded on")
        check(controller.hostingView.acceptsFirstMouse(for: nil) && !controller.hostingView.needsPanelToBecomeKey, "content takes the first click without key")
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(panel.frame) }
        check(onScreen, "panel inside a screen's visible frame (\(panel.frame))")
        if let anchor = controller.statusItemAnchor(), let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }),
           !ScreenGeometry(screen: screen).isBehindNotch(anchor) {
            let clampedX = abs(panel.frame.midX - anchor.midX) < 1 || abs(panel.frame.maxX - (screen.visibleFrame.maxX - PanelPlacement.margin)) < 1
            check(clampedX && abs(panel.frame.maxY - min(anchor.minY - PanelPlacement.gap, screen.visibleFrame.maxY)) <= 2, "anchored under the status item (anchor \(anchor), panel \(panel.frame))")
        } else {
            print("INFO status item hidden or behind the notch; panel placed top-right at \(panel.frame)")
        }
        // Optional picture of the panel for a human to look at later (not a check).
        if let path = ProcessInfo.processInfo.environment["MICK_SMOKE_SNAPSHOT"], !path.isEmpty,
           let rep = controller.hostingView.bitmapImageRepForCachingDisplay(in: controller.hostingView.bounds) {
            controller.hostingView.cacheDisplay(in: controller.hostingView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        let content = controller.model.content
        let engine = delegate.engine!
        check(engine.moves?.moves.count == 11, "bundled moves.json loaded (11 moves)")
        let moves = content.items.dropFirst().compactMap { engine.moves?.move(id: $0.id) }
        let isRoutine = content.items.first?.id == Routine.standUp.id && content.items.count == 3 && moves.count == 2
            && (moves[0].id == Routine.walkID || moves[0].area != moves[1].area)
        check(engine.lines != nil, "bundled lines.json loaded")
        // Mick's voice (#9): the opener comes from the pool its precedence picks,
        // rendered for the sitting time, and is recorded in the rotation.
        let ignored = MickMemory.ignoredToday(engine.state, now: engine.now)
        let minutes = engine.reminder.panel?.sittingMinutes ?? -1
        // Long sit is judged by sitting time at show time, not by the routine: the walk
        // also takes part in the normal rotation (§10.1), so a normal routine can start
        // with it.
        let kind: Routine.Kind = minutes >= 2 * engine.config.sitThresholdMinutes ? .longSit : .normal
        let openerPool = LinePool.opener(ignoredToday: ignored, kind: kind)
        let rendered = engine.lines?.lines(openerPool).map { SpokenTime.render($0.text, sittingMinutes: minutes) } ?? []
        check(rendered.contains(content.opener), "opener from \(openerPool.rawValue): \(content.opener)")
        check(engine.state.rotation.usedLineIDs[openerPool.rawValue]?.count == 1, "opener recorded in the rotation")
        check(!content.opener.isEmpty && isRoutine,"opener and a routine: Stand up + 2 moves from different areas (\(content.items.map(\.id)))")
        let saved = engine.state.rotation
        check(saved.lastAreas == moves.map(\.area) && moves.allSatisfy { saved.usedMoveIDs.contains($0.id) }, "rotation recorded (\(saved.usedMoveIDs))")
        // The bell (§6.5): rings once as the panel appears, only when it's on.
        let expected = engine.config.sound ? 1 : 0
        check(engine.bellCount == expected && delegate.bell.playCount == expected,
              "bell \(engine.config.sound ? "on: rang once" : "off: silent") (rang \(delegate.bell.playCount))")
    }

    // MARK: - Settings and uninstall (#11)

    private var recordingLoginItem: RecordingLoginItem? { delegate.loginItem.service as? RecordingLoginItem }

    private func openSettings() async {
        guard let item = statusItem().menuItem(StatusItemController.settingsTitle) else {
            check(false, "menu has Settings…")
            return
        }
        check(statusItem().choose(item), "chose Settings…")
        await waitFor(.seconds(1)) { self.delegate.settings.isVisible }
        check(delegate.settings.isVisible, "Settings window shown")
        let size = delegate.settings.window?.contentView?.fittingSize ?? .zero
        check(size.width > 300 && size.height > 200, "Settings window has content (\(Int(size.width))×\(Int(size.height)))")
        try? await Task.sleep(for: .milliseconds(300))
        snapshot(delegate.settings.window?.contentView, env: "MICK_SMOKE_SETTINGS_SNAPSHOT")
    }

    private func savedConfig() -> ConfigFile.Parsed {
        guard let data = try? Data(contentsOf: engine().home.config) else { return .unreadable("missing") }
        return ConfigFile.parse(data)
    }

    private func runSettings() async {
        let engine = engine()
        let home = engine.home
        let login = delegate.loginItem!
        check(recordingLoginItem != nil, "login item simulated under MICK_HOME (never the real one)")
        check(engine.createdHome && recordingLoginItem?.registerCalls == 1 && login.isOn, "open at login turned on by default on first launch")

        await openSettings()
        check(!NSApp.isActive, "opening Settings in the smoke check didn't take focus")

        // Changes from the window are written to config.json.
        let editor = SettingsEditor(engine: engine)
        editor.set(\.sitThresholdMinutes, 42)
        editor.set(\.sound, true)
        editor.setQuietHours(true)
        let expected = MickConfig(sitThresholdMinutes: 42, quietHours: .suggested, sound: true)
        check(engine.config == expected, "settings applied (\(engine.config))")
        check(savedConfig() == .config(expected, problems: []), "settings written to config.json")
        editor.binding(\.showDelaySeconds, in: MickConfig.showDelayRange).wrappedValue = 99_999
        check(engine.config.showDelaySeconds == MickConfig.showDelayRange.upperBound, "typed values are kept inside their range")
        editor.setQuietHours(false)
        check(engine.config.quietHours == nil, "quiet hours off")

        // Hand edits are picked up without a relaunch.
        let edited = #"{"sit_threshold_minutes": 12, "show_delay_seconds": 4}"#
        try? Data(edited.utf8).write(to: home.config, options: .atomic)
        await waitFor(.seconds(2)) { engine.config == MickConfig(sitThresholdMinutes: 12, showDelaySeconds: 4) }
        check(engine.config == MickConfig(sitThresholdMinutes: 12, showDelaySeconds: 4), "hand edit to config.json picked up live (\(engine.config))")
        await waitFor(.seconds(1)) { self.statusItem().detailLine?.contains("12m") == true }
        check(statusItem().detailLine?.contains("12m") == true, "menu follows the hand edit (\(statusItem().detailLine ?? "none"))")

        // Invalid values fall back to defaults and are logged.
        try? Data(#"{"sit_threshold_minutes": 0, "show_delay_seconds": "soon", "sound": true}"#.utf8).write(to: home.config, options: .atomic)
        await waitFor(.seconds(2)) { engine.config == MickConfig(sound: true) }
        check(engine.config == MickConfig(sound: true), "invalid hand-edited values fall back to defaults")
        let log = (try? String(contentsOf: home.log, encoding: .utf8)) ?? ""
        check(log.contains("sit_threshold_minutes 0 is out of range") && log.contains("show_delay_seconds \"soon\""), "invalid values logged")

        // Open at login: approval needed, then an error, both shown plainly.
        recordingLoginItem?.statusAfterRegister = .requiresApproval
        login.setEnabled(false)
        check(!login.isOn && login.note == nil, "open at login off")
        login.setEnabled(true)
        check(login.isOn && login.note == LoginItemNote.requiresApproval && login.offersSystemSettings,
              "requires approval: plain line pointing to Login Items (\(login.note ?? "none"))")
        login.openSystemSettings()
        check(recordingLoginItem?.openSettingsCalls == 1, "the line offers to open Login Items settings")
        recordingLoginItem?.nextError = NSError(domain: "SMAppServiceErrorDomain", code: Int(kSMErrorLaunchDeniedByUser),
                                                userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        login.setEnabled(false)
        check(login.errorMessage != nil && login.note == login.errorMessage, "a registration error is shown (\(login.errorMessage ?? "none"))")
        let log2 = (try? String(contentsOf: home.log, encoding: .utf8)) ?? ""
        check(log2.contains("open at login: Couldn't turn off"), "the error is logged")

        // The bell's Play button.
        let before = delegate.bell.playCount
        delegate.bell.play()
        check(delegate.bell.playCount == before + 1, "the bell plays on demand (muted in the smoke check)")
        delegate.settings.close()
        check(!delegate.settings.isVisible, "Settings window closes")
    }

    private func runUninstall() async {
        let engine = engine()
        let home = engine.home
        await openSettings()
        check(UninstallConfirmation.message(home: home).contains(home.url.path), "the confirmation names the folder it deletes")
        check(recordingLoginItem?.status == .enabled, "login item registered before uninstall")

        // What the confirmation's Uninstall button runs (the alert itself is modal).
        delegate.uninstall(activate: false)
        check(!FileManager.default.fileExists(atPath: home.url.path), "Mick's home directory deleted")
        check(recordingLoginItem?.unregisterCalls == 1 && recordingLoginItem?.status == .notRegistered, "login item unregistered")
        check(engine.isUninstalled && !engine.isRunning, "engine stopped")
        check(!statusItem().isInMenuBar && !delegate.settings.isVisible, "status item removed and Settings closed")
        let window = delegate.uninstalled
        await waitFor(.seconds(1)) { window?.isVisible == true }
        check(window?.isVisible == true && window?.result.removedHome == true, "the uninstalled window is shown")
        check(UninstalledView.commands.first == "/plugin uninstall mick@mick", "it shows /plugin uninstall mick@mick (the install id's counterpart)")
        let size = window?.window.contentView?.fittingSize ?? .zero
        check(size.width > 300 && size.height > 200, "the uninstalled window has content (\(Int(size.width))×\(Int(size.height)))")
        snapshot(window?.window.contentView, env: "MICK_SMOKE_UNINSTALL_SNAPSHOT")

        // A still-installed plugin writes nothing and creates nothing.
        if let hook = delegate.options.smokeHook {
            check(runHook(path: hook, home: home, kind: "prompt", session: "after-uninstall") == 0, "hook exited 0 after uninstall")
            check(!FileManager.default.fileExists(atPath: home.url.path), "the hook didn't recreate Mick's home")
        }
        try? await Task.sleep(for: .milliseconds(300))
        check(!FileManager.default.fileExists(atPath: home.url.path), "nothing recreated Mick's home")

        print(failures.isEmpty ? "SMOKE OK" : "SMOKE FAILED: \(failures.count)")
        fflush(stdout)
        guard failures.isEmpty, let window else { exit(1) }
        window.quit()  // NSApp.terminate, as the Quit Mick button does
    }

    /// Optional picture of a window for a human to look at later (not a check).
    private func snapshot(_ view: NSView?, env: String) {
        guard let view, let path = ProcessInfo.processInfo.environment[env], !path.isEmpty,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func seconds(_ d: Duration) -> String {
        String(format: "%.2f s", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    private func frontmostUnchanged(_ before: pid_t?, me: pid_t) -> Bool {
        let now = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Mick must never become frontmost. Another app coming forward on its own (a
        // launch elsewhere on a shared machine) is noted but isn't Mick taking focus:
        // a non-activating panel can't hand focus to a third app.
        if now != me, now != before {
            let name = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            print("INFO frontmost app changed to \(name) during the check, not to Mick")
        }
        return now != me && NSApp.isActive == false
    }

    private func waitFor(_ timeout: Duration, _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func runHook(path: String, home: MickHome, kind: String, session: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [kind]
        process.environment = ["MICK_HOME": home.url.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        process.standardInput = stdin
        do {
            try process.run()
        } catch {
            print("FAIL couldn't run the hook: \(error.localizedDescription)")
            return -1
        }
        let payload = #"{"session_id":"\#(session)","cwd":"/tmp/mick-smoke","hook_event_name":"UserPromptSubmit","prompt":"SMOKE-SECRET"}"#
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
