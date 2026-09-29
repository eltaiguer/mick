import Foundation
import MickCore
import Observation

/// The app's single owner of state (SPEC §6): loads config and state from Mick's
/// home, follows the events file, applies events to session bookkeeping, and saves.
/// The app observes it (`@Observable`) and renders; it holds no logic of its own.
@MainActor
@Observable
public final class MickEngine {
    public struct Tunables: Sendable {
        public var rotateBytes: UInt64 = EventFilePolicy.rotateBytes
        public var drainDelay: TimeInterval = EventFilePolicy.drainDelay
        /// Prune, re-check the hooks status and poke the tailer this often.
        public var tickInterval: TimeInterval = 60
        /// Poll system idle time this often (§6.3).
        public var pollInterval: TimeInterval = SittingTimer.pollInterval
        /// Poll this often instead while a reminder is visible or waiting to settle, to
        /// catch the "did you get up" idle stretch (§6.3, §8).
        public var followUpPollInterval: TimeInterval = SittingTimer.followUpPollInterval
        /// The reminder's lifetime timings (§7, §9.2). Only simulation mode shortens them.
        public var reminderTimings: Reminder.Timings = .standard
        /// How long a snooze, pause or resume line stays in the dropdown's status line
        /// (§6.4 "briefly"). The menu closes when you pick an item, so it has to outlast
        /// that to be seen on the next open.
        public var announcementDuration: TimeInterval = 60
        /// How long a burst of changes to `config.json` settles before it's reread.
        public var configDebounce: TimeInterval = 0.15
        public init() {}
    }

    public let home: MickHome
    @ObservationIgnored public let log: any MickLogger
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let idleSeconds: @MainActor () -> Double
    @ObservationIgnored private let tunables: Tunables

    public private(set) var config: MickConfig = .defaults
    public private(set) var state: MickState
    public private(set) var hooks: HooksStatus = .notDetected
    /// True when this launch created Mick's home directory.
    public private(set) var createdHome = false
    public private(set) var configOutcome: LoadOutcome = .missing
    public private(set) var stateOutcome: LoadOutcome = .missing
    public private(set) var isRunning = false
    /// The reminder lifecycle: scheduled check, visible panel or settling (§7, §9).
    /// In memory only (§12.1): a relaunch drops it.
    public private(set) var reminder: Reminder
    /// What the panel shows if the move catalogue couldn't be loaded. With a catalogue,
    /// each reminder gets a routine composed at show time (§10.1).
    public var reminderContent: ReminderContent = .standard
    /// The move catalogue (`moves.json`, §10.1); nil if the bundled file was unusable.
    public private(set) var moves: MoveCatalog?
    /// Mick's line pools (`lines.json`, §10.2); nil if the bundled file was unusable.
    public private(set) var lines: LineCatalog?
    /// A snooze, pause or resume line showing in the status line until `until`.
    public private(set) var announcement: (text: String, until: Date)?
    /// The lines picked for the visible reminder; each done line is committed to the
    /// rotation only when it shows.
    @ObservationIgnored private var reminderLines: Voice.ReminderLines?
    /// The status line's current pick. A new one is picked when the menu opens or the
    /// pool changes (calm, armed, glaring), not on every re-render.
    @ObservationIgnored private var statusPick: (pool: LinePool, line: Line)?

    /// Called on the main actor after each batch of event lines is applied, with every
    /// line's result. Later tickets react to live prompts and stops here.
    @ObservationIgnored public var onRecords: (([IntakeRecord], EventOrigin) -> Void)?
    /// Called on the main actor with every batch of reminder effects (show, tick
    /// updates, done line, close). The app's panel renders from these.
    @ObservationIgnored public var onReminder: (([Reminder.Effect]) -> Void)?
    /// Called on the main actor after a reminder settles and its outcome is applied.
    @ObservationIgnored public var onSettled: ((Settlement) -> Void)?
    /// A Mick line shown briefly in the dropdown's status line after snooze, pause or
    /// resume (§6.4). In memory only.
    public private(set) var notice: StatusNotice?
    /// The most recent settlement this launch (diagnostics and the smoke check).
    public private(set) var lastSettlement: Settlement?
    /// `reminders.jsonl`.
    @ObservationIgnored public let reminderLog: ReminderLog

    /// Called on the main actor when a panel appears and the bell is on (§6.5). The
    /// app plays the sound here.
    @ObservationIgnored public var onBell: (() -> Void)?
    /// How many times the bell rang this launch (tests and the smoke check).
    public private(set) var bellCount = 0
    /// True once `uninstall()` has deleted Mick's home: nothing is saved after that.
    public private(set) var isUninstalled = false

    @ObservationIgnored private var configWatcher: ConfigWatcher?
    /// The bytes of `config.json` as last read or written, so the watcher can tell a
    /// hand edit from Mick's own save or an unrelated change in the directory.
    @ObservationIgnored private var lastConfigData: Data?
    @ObservationIgnored private var tailer: EventTailer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pollTimer: Timer?
    /// When `willSleep` / `sessionDidResignActive` arrived. In memory only.
    @ObservationIgnored private var sleptAt: Date?
    @ObservationIgnored private var resignedAt: Date?
    @ObservationIgnored private var lastReset: SittingTimer.Reset?
    @ObservationIgnored private var reminderTimer: Timer?
    @ObservationIgnored public let activity: ActivityAssertion
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()

    /// - Parameter idleSeconds: seconds since the last keyboard or mouse input
    ///   (`SystemIdle.seconds` in the app; a fake in tests).
    /// - Parameter moves: the move catalogue; nil loads the bundled `moves.json` at start.
    /// - Parameter lines: the line pools; nil loads the bundled `lines.json` at start.
    public init(home: MickHome, log: any MickLogger, tunables: Tunables = Tunables(),
                clock: @escaping @Sendable () -> Date = { Date() },
                idleSeconds: @escaping @MainActor () -> Double = { SystemIdle.seconds() },
                activity: ActivityAssertion = ActivityAssertion(),
                moves: MoveCatalog? = nil, lines: LineCatalog? = nil) {
        self.home = home
        self.moves = moves
        self.lines = lines
        self.activity = activity
        self.reminder = Reminder(timings: tunables.reminderTimings)
        self.reminderLog = ReminderLog(url: home.reminders)
        self.log = log
        self.tunables = tunables
        self.clock = clock
        self.idleSeconds = idleSeconds
        self.state = .defaults(now: clock())
    }

    public var now: Date { clock() }

    /// Creates Mick's home (0700) if needed, loads config and state (defaults when
    /// missing; corrupted files moved aside), reads the backlog and starts watching.
    public func start() throws {
        guard !isRunning else { return }
        let now = clock()
        createdHome = try home.ensureExists()
        log.log("Mick starting; home \(home.url.path)\(createdHome ? " (created)" : "")")
        if moves == nil {
            do { moves = try MoveCatalog.bundled() } catch {
                log.log("couldn't load the bundled moves.json (\(error)); reminders use a fixed routine")
            }
        }
        if lines == nil {
            do { lines = try LineCatalog.bundled() } catch {
                log.log("couldn't load the bundled lines.json (\(error)); Mick uses fixed lines")
            }
        }

        let (loadedConfig, cOutcome) = readConfig(now: now, atLaunch: true) ?? (.defaults, .missing)
        config = loadedConfig
        configOutcome = cOutcome
        if cOutcome != .loaded { saveConfig() }

        let (loadedState, sOutcome) = JSONFileStore.load(MickState.self, from: home.state, defaults: .defaults(now: now), now: now, log: log)
        state = loadedState
        stateOutcome = sOutcome
        // Quitting for the break-reset time counts as a break (decision 17). Only the
        // loaded file's last_active_at counts; defaults use now, so they never reset.
        if let reset = SittingTimer.apply(.launch, config: config, now: now, to: &state) { logReset(reset) }
        rollOver(now: now)
        pollIdle(now: now, save: false)
        let pruned = SessionBook.prune(&state, now: now)
        if !pruned.isEmpty { log.log("pruned \(pruned.count) session(s) with no event for 2 hours") }
        refreshHooks(now: now)
        saveState()

        let tailer = EventTailer(
            directory: home.url, startOffset: state.eventsOffset,
            rotateBytes: tunables.rotateBytes, drainDelay: tunables.drainDelay, log: log
        ) { [weak self] batch in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(batch) }
            }
        }
        self.tailer = tailer
        tailer.start()

        let timer = Timer(timeInterval: tunables.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = min(10, tunables.tickInterval / 4)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let watcher = ConfigWatcher(file: home.config, debounce: tunables.configDebounce) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reloadConfigIfChanged() }
            }
        }
        configWatcher = watcher
        watcher.start()

        isRunning = true
        updatePollRate()
        updateActivity()
    }

    /// The idle poll interval right now: 5 s during a reminder's follow-up window,
    /// 30 s otherwise (§6.3).
    public var currentPollInterval: TimeInterval {
        reminder.isInFollowUp ? tunables.followUpPollInterval : tunables.pollInterval
    }

    /// (Re)creates the repeating idle poll when its interval should change.
    private func updatePollRate() {
        guard isRunning else { return }
        let interval = currentPollInterval
        if let pollTimer, pollTimer.isValid, pollTimer.timeInterval == interval { return }
        pollTimer?.invalidate()
        // A repeating Timer, not asyncAfter, which runs late by ~5 % (signals spike).
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = min(3, interval / 10)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    public func stop() {
        configWatcher?.stop()
        configWatcher = nil
        timer?.invalidate()
        timer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        tailer?.stop()
        tailer = nil
        reminderTimer?.invalidate()
        reminderTimer = nil
        if isRunning { saveState() }
        isRunning = false
        activity.hold(false)
    }

    /// Periodic housekeeping: prune idle sessions, re-evaluate the 7-day warning,
    /// and re-check the events file in case a file event was missed.
    public func tick() {
        let now = clock()
        var changed = !SessionBook.prune(&state, now: now).isEmpty
        changed = rollOver(now: now) || changed
        if changed { saveState() }
        refreshHooks(now: now)
        tailer?.poke()
        // A safety net next to the config watcher.
        reloadConfigIfChanged()
        updateActivity()
    }

    // MARK: - Sitting timer

    /// Reads system idle time, records last-active and applies the break rule (§6.3).
    /// Runs every `pollInterval`; public so tests and the app can poll on demand.
    public func poll() {
        pollIdle(now: clock(), save: true)
    }

    private func pollIdle(now: Date, save: Bool) {
        let idle = idleSeconds()
        if let reset = SittingTimer.apply(.poll(idleSeconds: idle), config: config, now: now, to: &state) {
            logReset(reset)
        } else {
            lastReset = nil
        }
        // The follow-up window's "did you get up" watch (§8).
        reminder.observeIdle(idle, now: now)
        if Controls.clearExpiredSnooze(&state, now: now) { log.log("snooze over") }
        rollOver(now: now)
        if save { saveState() }
    }

    /// Local midnight wipes Mick's memory of today (§8).
    @discardableResult
    private func rollOver(now: Date) -> Bool {
        guard MickMemory.rollOver(&state, now: now) else { return false }
        log.log("new day \(state.today.date): Mick's memory of today reset")
        return true
    }

    /// `NSWorkspace.willSleep`.
    public func willSleep() {
        let now = clock()
        sleptAt = now
        pollIdle(now: now, save: true)
    }

    /// `NSWorkspace.didWake`: sleeping for the break-reset time counts as a break.
    public func didWake() {
        let now = clock()
        if let reset = SittingTimer.apply(.wake(sleptAt: sleptAt), config: config, now: now, to: &state) { logReset(reset) }
        sleptAt = nil
        saveState()
    }

    /// `NSWorkspace.sessionDidResignActive` (fast user switching away).
    public func sessionDidResignActive() {
        let now = clock()
        resignedAt = now
        pollIdle(now: now, save: true)
    }

    /// `NSWorkspace.sessionDidBecomeActive`: away for the break-reset time counts as a break.
    public func sessionDidBecomeActive() {
        let now = clock()
        if let reset = SittingTimer.apply(.sessionBecameActive(resignedAt: resignedAt), config: config, now: now, to: &state) {
            logReset(reset)
        }
        resignedAt = nil
        saveState()
    }

    /// The icon for the current state (§6.4).
    public var icon: MenuBarIcon {
        MenuBarIcon.current(hooks: hooks, state: state, config: config, now: clock())
    }

    /// The dropdown's plain detail line (§6.4).
    public var sittingDetail: String {
        SittingTimer.detailLine(state, config: config, now: clock())
    }

    private func logReset(_ reset: SittingTimer.Reset) {
        let why = switch reset {
        case .idle(let s): "idle \(Int(s))s"
        case .relaunch(let s): "away \(Int(s))s before launch"
        case .sleep(let s): "slept \(Int(s))s"
        case .userSwitch(let s): "switched away \(Int(s))s"
        }
        // Idle resets repeat every poll during a break; log only the first of a run.
        if case .idle = reset, case .idle? = lastReset { return }
        lastReset = reset
        log.log("sitting timer reset (\(why))")
    }

    /// Blocks until the tailer has processed everything queued so far (tests). Batches
    /// it produced are delivered to the main actor afterwards.
    public func flushTailer() {
        tailer?.waitUntilIdle()
    }

    // MARK: - Intake

    func handle(_ batch: TailBatch) {
        let now = clock()
        var records: [IntakeRecord] = []
        var effects: [Reminder.Effect] = []
        // One line at a time, so the reminder sees the sessions as they were right
        // after each event (a hand-off picks from the sessions running at that point).
        for line in batch.lines {
            let record = Intake.apply(lines: [line], origin: batch.origin, now: now, to: &state)[0]
            records.append(record)
            if case .failure(let error) = record.result {
                log.log("skipped malformed event line (\(error)): \(record.line.prefix(200))")
            }
            // Only live events drive reminders; backlog updates bookkeeping only (§6.3).
            if batch.origin == .live, let event = record.event, case .applied(let change, let canTrigger)? = record.disposition {
                effects += reminder.sessionChanged(change, sessionID: event.sessionID, canTrigger: canTrigger,
                                                   state: state, config: config, now: now)
            }
        }
        if batch.source == .main, let offset = batch.offset { state.eventsOffset = offset }
        SessionBook.prune(&state, now: now)
        refreshHooks(now: now)
        saveState()
        if !records.isEmpty { onRecords?(records, batch.origin) }
        deliver(effects)
    }

    // MARK: - Reminder

    /// Runs whatever reminder timers are due (the one-shot timer calls this; tests call
    /// it after moving their clock).
    public func runReminderTimers() {
        let now = clock()
        // A routine is composed whenever a check could show, and its rotation is only
        // committed if the panel actually shows. Long sit is judged at show time (§10.1).
        var composition: Routine.Composition?
        var voice: Voice.ReminderLines?
        var content = reminderContent
        if reminder.check != nil {
            let kind = Routine.kind(state, config: config, now: now)
            if let moves {
                let c = Routine.compose(kind, catalog: moves, rotation: state.rotation, using: &rng)
                composition = c
                content.items = c.items
            }
            // The opener by precedence (ignored tier, long sit, normal), and the done
            // lines, rendered for the sitting time at show time (§10.2).
            if let lines {
                let ignored = MickMemory.ignoredToday(state, now: now)
                voice = Voice.pickReminderLines(kind: kind, ignoredToday: ignored, catalog: lines, rotation: state.rotation, using: &rng)
                if let voice { Voice.apply(voice, kind: kind, sittingMinutes: sittingMinutes(now: now), to: &content) }
            }
        }
        let effects = reminder.advance(state: state, config: config, now: now, idleSeconds: idleSeconds(), content: content)
        if effects.contains(where: { if case .show = $0 { true } else { false } }) {
            if let composition {
                state.rotation.usedMoveIDs = composition.rotation.usedMoveIDs
                state.rotation.lastAreas = composition.rotation.lastAreas
                log.log("routine (\(composition.kind == .longSit ? "long sit" : "normal")): \(composition.items.map(\.id).joined(separator: ", "))")
            }
            reminderLines = voice
            if let voice {
                state.rotation.usedLineIDs[voice.openerPool.rawValue] = voice.rotation.usedLineIDs[voice.openerPool.rawValue]
                log.log("opener from \(voice.openerPool.rawValue): \(voice.opener.id)")
            }
            saveState()
        }
        deliver(effects)
    }

    /// A checkbox on the panel.
    public func setReminderItem(_ index: Int, ticked: Bool) {
        deliver(reminder.setTicked(index, ticked, now: clock()))
    }

    /// "Not now".
    public func dismissReminder() {
        deliver(reminder.dismiss(now: clock()))
    }

    /// Snooze from the panel: snoozes until `until` and settles the reminder at once as
    /// the Snoozed outcome, with no penalty (§8).
    public func snoozeReminder(until: Date) {
        guard reminder.panel != nil else { return }
        Controls.snooze(&state, until: until)
        deliver(reminder.snooze(now: clock()))
        announce(.snooze)
        saveState()
    }

    // MARK: - Mick's voice (§10.2)

    private func sittingMinutes(now: Date) -> Int {
        Int(SittingTimer.sittingSeconds(state, now: now) / 60)
    }

    /// Picks the next line from `pool` and commits it to the rotation (saved with state).
    private func say(_ pool: LinePool) -> Line? {
        guard let lines, let pick = Lines.pick(pool, catalog: lines, rotation: state.rotation, using: &rng) else { return nil }
        state.rotation.usedLineIDs[pool.rawValue] = pick.rotation.usedLineIDs[pool.rawValue]
        saveState()
        return pick.line
    }

    /// Shows a snooze, pause or resume line in the dropdown's status line for a while
    /// (§6.4). Returns the line. Snooze, pause and resume never reset the sitting timer.
    @discardableResult
    public func announce(_ pool: LinePool) -> String? {
        let now = clock()
        guard let line = say(pool) else { return nil }
        let text = SpokenTime.render(line.text, sittingMinutes: sittingMinutes(now: now))
        announcement = (text, now.addingTimeInterval(tunables.announcementDuration))
        log.log("mick says (\(pool.rawValue)): \(line.id)")
        return text
    }

    /// The dropdown's Mick status line (§6.4): a recent snooze, pause or resume line,
    /// otherwise a line from the calm, armed or glaring pool for the icon, with the
    /// sitting time filled in. Keeps its pick until the pool changes or
    /// `nextStatusLine()` is called.
    public func statusLine() -> String {
        let now = clock()
        if let noticeLine { return noticeLine }
        if let announcement, now < announcement.until { return announcement.text }
        let pool = LinePool.status(for: icon)
        if statusPick?.pool != pool {
            statusPick = say(pool).map { (pool, $0) }
        }
        guard let statusPick else { return "Mick's in your corner." }
        return SpokenTime.render(statusPick.line.text, sittingMinutes: sittingMinutes(now: now))
    }

    /// Moves the status line on to the next line of its pool (each time the menu opens).
    public func nextStatusLine() {
        statusPick = nil
    }

    /// A line for onboarding (§6.6), from the `onboarding` pool.
    public func onboardingLine() -> String {
        say(.onboarding)?.text ?? "So you wanna be a contender. Install the thing."
    }

    /// Commits a done line to the rotation once it shows.
    private func markShown(_ pool: LinePool) {
        guard let lines, let voice = reminderLines else { return }
        let line = pool == .doneAll ? voice.doneAll : voice.donePartial
        Lines.markUsed(line, in: pool, catalog: lines, rotation: &state.rotation)
        saveState()
    }

    // MARK: - Snooze, pause, Stretch now (§6.4, §8)

    /// Snooze from the menu or the panel. A visible panel settles at once as the
    /// Snoozed outcome (no penalty, §8); a scheduled check is dropped at show time.
    /// Never touches the sitting timer.
    public func snooze(_ option: SnoozeOption) {
        let now = clock()
        let until = option.until(from: now)
        log.log("snoozed until \(MickDate.string(from: until)) (\(option.rawValue))")
        if reminder.panel != nil {
            snoozeReminder(until: until)
        } else {
            Controls.snooze(&state, until: until)
            saveState()
        }
        show(notice: .snooze(option), now: now)
    }

    /// Pause until resumed; persists across relaunch. Never touches the sitting timer.
    public func pause() {
        let now = clock()
        guard !state.paused else { return }
        Controls.pause(&state)
        saveState()
        log.log("paused")
        show(notice: .pause, now: now)
    }

    /// Ends a pause and any snooze. Never touches the sitting timer.
    public func resume() {
        let now = clock()
        guard state.paused || Controls.isSnoozed(state, now: now) else { return }
        Controls.resume(&state)
        saveState()
        log.log("resumed")
        show(notice: .resume, now: now)
    }

    public var isPaused: Bool { state.paused }
    public var isSnoozed: Bool { Controls.isSnoozed(state, now: clock()) }

    /// The Mick line for the dropdown's status line while a notice is showing, else nil.
    public var noticeLine: String? {
        guard let notice, notice.isShowing(at: clock()) else { return nil }
        return notice.text
    }

    private func show(notice action: StatusNotice.Action, now: Date) {
        notice = StatusNotice(text: StatusNotice.line(for: action), now: now)
    }

    /// "Stretch now" is enabled only while no reminder is scheduled, visible or
    /// settling (§6.4).
    public var canStretchNow: Bool { reminder.canStretchNow }

    /// Stretch now (§8): a normal routine in a panel with no session attached. Returns
    /// false (and does nothing) while a reminder is scheduled, visible or settling.
    @discardableResult
    public func stretchNow() -> Bool {
        let now = clock()
        guard reminder.canStretchNow else { return false }
        var content = reminderContent
        var composition: Routine.Composition?
        if let moves {
            // Always a normal routine, even after a long sit (§10.1).
            let c = Routine.compose(.normal, catalog: moves, rotation: state.rotation, using: &rng)
            composition = c
            content.items = c.items
        }
        // Mick's voice (§10.2): the opener by precedence for a normal routine, and the
        // done lines, rendered for the sitting time.
        var voice: Voice.ReminderLines?
        if let lines {
            let ignored = MickMemory.ignoredToday(state, now: now)
            voice = Voice.pickReminderLines(kind: .normal, ignoredToday: ignored, catalog: lines, rotation: state.rotation, using: &rng)
            if let voice { Voice.apply(voice, kind: .normal, sittingMinutes: sittingMinutes(now: now), to: &content) }
        }
        let sitting = Int(SittingTimer.sittingSeconds(state, now: now) / 60)
        let effects = reminder.stretchNow(content: content, sittingMinutes: sitting, now: now)
        guard !effects.isEmpty else { return false }
        reminderLines = voice
        if let voice {
            state.rotation.usedLineIDs[voice.openerPool.rawValue] = voice.rotation.usedLineIDs[voice.openerPool.rawValue]
            log.log("opener from \(voice.openerPool.rawValue): \(voice.opener.id)")
        }
        if let composition {
            state.rotation.usedMoveIDs = composition.rotation.usedMoveIDs
            state.rotation.lastAreas = composition.rotation.lastAreas
            log.log("routine (stretch now): \(composition.items.map(\.id).joined(separator: ", "))")
        }
        saveState()
        deliver(effects)
        return true
    }

    /// True while the App Nap activity is held (§6.3).
    public var isHoldingActivity: Bool { activity.isHeld }

    private func deliver(_ effects: [Reminder.Effect]) {
        effects.forEach(logEffect)
        for effect in effects {
            switch effect {
            case .allTicked: markShown(.doneAll)
            case .closing: markShown(.donePartial)
            default: break
            }
        }
        let settlements = effects.compactMap { if case .settled(let s) = $0 { Settlement(s) } else { nil } }
        settlements.forEach(settle)
        scheduleReminderTimer()
        updatePollRate()
        updateActivity()
        if !effects.isEmpty { onReminder?(effects) }
        // The bell rings as a panel appears, only if it's turned on (§6.5).
        if config.sound, effects.contains(where: { if case .show = $0 { true } else { false } }) {
            bellCount += 1
            log.log("bell")
            onBell?()
        }
        settlements.forEach { onSettled?($0) }
    }

    /// Applies a settled reminder's outcome to Mick's memory, saves it, and appends the
    /// reminder log line (§8, §12.3).
    private func settle(_ settlement: Settlement) {
        let now = clock()
        let before = state.sittingSince
        settlement.apply(config: config, now: now, to: &state)
        lastSettlement = settlement
        saveState()
        let s = settlement.settling
        var detail = "\(settlement.outcome.rawValue); closed \(s.reason.rawValue), ticked \(s.panel.ticked.count)/\(s.panel.content.items.count), max idle \(Int(s.panel.maxIdleSeconds))s"
        if s.panel.isManual { detail += ", manual" }
        if state.sittingSince != before { detail += "; sitting timer reset" }
        log.log("reminder settled (\(detail))")
        do {
            try reminderLog.append(settlement.record)
        } catch {
            log.log("couldn't append to reminders.jsonl: \(error.localizedDescription)")
        }
    }

    /// One one-shot `Timer` for the next reminder deadline, with zero tolerance
    /// (`asyncAfter` runs ~5 % late; signals spike, #2).
    private func scheduleReminderTimer() {
        reminderTimer?.invalidate()
        reminderTimer = nil
        guard isRunning, let deadline = reminder.nextDeadline else { return }
        let timer = Timer(timeInterval: max(0, deadline.timeIntervalSince(clock())), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runReminderTimers() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        reminderTimer = timer
    }

    private func updateActivity() {
        let wanted = isRunning && reminder.needsActivity(state)
        if activity.hold(wanted) {
            log.log(wanted ? "holding activity (session running or reminder live)" : "released activity")
        }
    }

    private func logEffect(_ effect: Reminder.Effect) {
        switch effect {
        case .scheduled(let s, let at, let from):
            let wait = Int(at.timeIntervalSince(clock()).rounded())
            log.log("reminder check scheduled for session \(s) in \(wait)s" + (from.map { " (handed off from \($0))" } ?? ""))
        case .rescheduled(let s, _): log.log("reminder check rescheduled for session \(s) (new prompt)")
        case .notScheduled(_, .notArmed), .notScheduled(_, .busy): break  // every prompt; too noisy
        case .notScheduled(let s, let b): log.log("prompt on session \(s) didn't schedule a reminder (\(b))")
        case .waitingForGap(let s): log.log("reminder for session \(s) waiting for a 3 s input gap")
        case .dropped(let s, let why): log.log("reminder check for session \(s) dropped (\(why))")
        case .show(let p): log.log(p.isManual ? "stretch now shown" : "reminder shown for session \(p.sessionID ?? "none")")
        case .updated: break
        case .allTicked: log.log("reminder: all items ticked")
        case .closing: log.log("reminder: closing with some ticked")
        case .closed(_, let why): log.log("reminder closed (\(why.rawValue))")
        case .settled: break  // logged with its outcome by settle(_:)
        }
    }

    private func refreshHooks(now: Date) {
        let status = HooksStatus.evaluate(lastEventAt: state.lastEventAt, now: now)
        if status != hooks {
            if !hooks.everDetected, status.everDetected { log.log("Claude Code hooks detected") }
            if case .stale = status { log.log("no Claude Code events in 7 days") }
            hooks = status
        }
    }

    // MARK: - Settings (§6.5, §11)

    /// A change from the Settings window: validated (out-of-range values take their
    /// defaults, logged), applied, and written to `config.json`. A scheduled check keeps
    /// the show delay it was scheduled with; the new values apply from the next one.
    public func updateConfig(_ new: MickConfig) {
        guard !isUninstalled else { return }
        let (valid, problems) = new.validated()
        problems.forEach { log.log("settings: \($0)") }
        // SwiftUI fields write back unchanged values (on focus loss, on close).
        guard valid != config || lastConfigData == nil else { return }
        log.log("settings changed: \(Self.describe(valid))")
        config = valid
        saveConfig()
        updateActivity()
    }

    /// Rereads `config.json` if its contents changed since Mick last read or wrote it
    /// (a hand edit). Values with the wrong type or out of range take their defaults
    /// and are logged; a file that isn't JSON at all keeps the current settings until
    /// it's fixed (and is never moved aside while Mick runs); a deleted file means
    /// defaults. The watcher calls this; so does the periodic tick, as a safety net.
    public func reloadConfigIfChanged() {
        guard isRunning, !isUninstalled else { return }
        let data = try? Data(contentsOf: home.config)
        guard data != lastConfigData else { return }
        guard let (loaded, _) = readConfig(now: clock(), atLaunch: false) else { return }
        guard loaded != config else { return }
        log.log("config.json changed by hand; now \(Self.describe(loaded))")
        config = loaded
        updateActivity()
    }

    /// Reads `config.json`. Returns nil (keep the current config) only for a live
    /// reload of a file that can't be parsed. At launch such a file is corrupt: moved
    /// aside and replaced with defaults (§12.2).
    private func readConfig(now: Date, atLaunch: Bool) -> (MickConfig, LoadOutcome)? {
        let url = home.config
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            log.log("config.json missing; using defaults")
            lastConfigData = nil
            return (.defaults, .missing)
        } catch {
            lastConfigData = nil
            guard atLaunch else {
                log.log("config.json unreadable (\(error.localizedDescription)); keeping the current settings")
                return nil
            }
            log.log("config.json unreadable (\(error.localizedDescription)); using defaults")
            return (.defaults, .corrupt(movedTo: JSONFileStore.moveAside(url, now: now, log: log)))
        }
        lastConfigData = data
        switch ConfigFile.parse(data) {
        case .config(let config, let problems):
            problems.forEach { log.log("config.json: \($0)") }
            return (config, .loaded)
        case .unreadable(let why):
            guard atLaunch else {
                log.log("config.json is \(why); keeping the current settings until it's fixed")
                return nil
            }
            let moved = JSONFileStore.moveAside(url, now: now, log: log)
            log.log("config.json corrupted (\(why)); moved to \(moved?.lastPathComponent ?? "nowhere") and replaced with defaults")
            return (.defaults, .corrupt(movedTo: moved))
        }
    }

    private static func describe(_ c: MickConfig) -> String {
        let quiet = c.quietHours.map { "\($0.start)-\($0.end)" } ?? "off"
        return "threshold \(c.sitThresholdMinutes)m, show delay \(c.showDelaySeconds)s, break reset \(c.breakResetMinutes)m, quiet hours \(quiet), bell \(c.sound ? "on" : "off")"
    }

    // MARK: - Uninstall (§13)

    public struct UninstallResult: Equatable, Sendable {
        /// Mick's home directory is gone.
        public var removedHome: Bool
        /// Anything that went wrong, in plain words.
        public var problems: [String]
    }

    /// Settings → Uninstall…: stops everything, unregisters the login item, deletes
    /// Mick's home directory, and saves nothing afterwards. With the directory gone, a
    /// still-installed plugin's hooks write nothing (§6.1). The app quits after showing
    /// the plugin uninstall command.
    @discardableResult
    public func uninstall(loginItem: LoginItemController?) -> UninstallResult {
        var problems: [String] = []
        log.log("uninstalling: removing \(home.url.path)")
        stop()
        if let loginItem {
            loginItem.refresh()
            if loginItem.status != .notRegistered {
                loginItem.setEnabled(false)
                if let message = loginItem.errorMessage { problems.append(message) }
            }
        }
        isUninstalled = true

        let path = home.url.path
        let fm = FileManager.default
        if !Self.isSafeToDelete(home.url, userHome: fm.homeDirectoryForCurrentUser) {
            problems.append("Refused to delete \(path): that isn't Mick's own folder.")
        } else if fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(at: home.url)
            } catch {
                problems.append("Couldn't delete \(path): \(error.localizedDescription)")
            }
        }
        let removed = !fm.fileExists(atPath: path)
        FileHandle.standardError.write(Data("Mick: uninstalled; \(path) \(removed ? "deleted" : "NOT deleted")\n".utf8))
        return UninstallResult(removedHome: removed, problems: problems)
    }

    /// A last guard before deleting Mick's home: never `/`, the user's home or any
    /// folder above it (a mistyped `MICK_HOME`).
    public static func isSafeToDelete(_ url: URL, userHome: URL) -> Bool {
        func parts(_ u: URL) -> [String] { u.standardizedFileURL.resolvingSymlinksInPath().pathComponents.filter { $0 != "/" } }
        let target = parts(url), home = parts(userHome)
        guard !target.isEmpty else { return false }
        // Refuse the home folder itself and anything that contains it.
        return !(target.count <= home.count && Array(home.prefix(target.count)) == target)
    }

    // MARK: - Saving

    private func saveState() {
        guard !isUninstalled else { return }
        do { try JSONFileStore.save(state, to: home.state) } catch { log.log("couldn't save state.json: \(error.localizedDescription)") }
    }

    private func saveConfig() {
        guard !isUninstalled else { return }
        do {
            try JSONFileStore.save(config, to: home.config)
            lastConfigData = try? Data(contentsOf: home.config)
        } catch {
            log.log("couldn't save config.json: \(error.localizedDescription)")
        }
    }
}
