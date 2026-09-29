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

    /// Called on the main actor after each batch of event lines is applied, with every
    /// line's result. Later tickets react to live prompts and stops here.
    @ObservationIgnored public var onRecords: (([IntakeRecord], EventOrigin) -> Void)?

    @ObservationIgnored private var tailer: EventTailer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pollTimer: Timer?
    /// When `willSleep` / `sessionDidResignActive` arrived. In memory only.
    @ObservationIgnored private var sleptAt: Date?
    @ObservationIgnored private var resignedAt: Date?
    @ObservationIgnored private var lastReset: SittingTimer.Reset?

    /// - Parameter idleSeconds: seconds since the last keyboard or mouse input
    ///   (`SystemIdle.seconds` in the app; a fake in tests).
    public init(home: MickHome, log: any MickLogger, tunables: Tunables = Tunables(),
                clock: @escaping @Sendable () -> Date = { Date() },
                idleSeconds: @escaping @MainActor () -> Double = { SystemIdle.seconds() }) {
        self.home = home
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

        let (loadedConfig, cOutcome) = JSONFileStore.load(MickConfig.self, from: home.config, defaults: .defaults, now: now, log: log)
        let (validConfig, problems) = loadedConfig.validated()
        problems.forEach { log.log("config.json: \($0)") }
        config = validConfig
        configOutcome = cOutcome
        if cOutcome != .loaded { saveConfig() }

        let (loadedState, sOutcome) = JSONFileStore.load(MickState.self, from: home.state, defaults: .defaults(now: now), now: now, log: log)
        state = loadedState
        stateOutcome = sOutcome
        // Quitting for the break-reset time counts as a break (decision 17). Only the
        // loaded file's last_active_at counts; defaults use now, so they never reset.
        if let reset = SittingTimer.apply(.launch, config: config, now: now, to: &state) { logReset(reset) }
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

        // A repeating Timer, not asyncAfter, which runs late by ~5 % (signals spike).
        let pollTimer = Timer(timeInterval: tunables.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        pollTimer.tolerance = min(3, tunables.pollInterval / 10)
        RunLoop.main.add(pollTimer, forMode: .common)
        self.pollTimer = pollTimer
        isRunning = true
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        tailer?.stop()
        tailer = nil
        if isRunning { saveState() }
        isRunning = false
    }

    /// Periodic housekeeping: prune idle sessions, re-evaluate the 7-day warning,
    /// and re-check the events file in case a file event was missed.
    public func tick() {
        let now = clock()
        if !SessionBook.prune(&state, now: now).isEmpty { saveState() }
        refreshHooks(now: now)
        tailer?.poke()
    }

    // MARK: - Sitting timer

    /// Reads system idle time, records last-active and applies the break rule (§6.3).
    /// Runs every `pollInterval`; public so tests and the app can poll on demand.
    public func poll() {
        pollIdle(now: clock(), save: true)
    }

    private func pollIdle(now: Date, save: Bool) {
        if let reset = SittingTimer.apply(.poll(idleSeconds: idleSeconds()), config: config, now: now, to: &state) {
            logReset(reset)
        } else {
            lastReset = nil
        }
        if save { saveState() }
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
        let records = Intake.apply(lines: batch.lines, origin: batch.origin, now: now, to: &state)
        for record in records {
            if case .failure(let error) = record.result {
                log.log("skipped malformed event line (\(error)): \(record.line.prefix(200))")
            }
        }
        if batch.source == .main, let offset = batch.offset { state.eventsOffset = offset }
        SessionBook.prune(&state, now: now)
        refreshHooks(now: now)
        saveState()
        if !records.isEmpty { onRecords?(records, batch.origin) }
    }

    private func refreshHooks(now: Date) {
        let status = HooksStatus.evaluate(lastEventAt: state.lastEventAt, now: now)
        if status != hooks {
            if !hooks.everDetected, status.everDetected { log.log("Claude Code hooks detected") }
            if case .stale = status { log.log("no Claude Code events in 7 days") }
            hooks = status
        }
    }

    // MARK: - Saving

    private func saveState() {
        do { try JSONFileStore.save(state, to: home.state) } catch { log.log("couldn't save state.json: \(error.localizedDescription)") }
    }

    private func saveConfig() {
        do { try JSONFileStore.save(config, to: home.config) } catch { log.log("couldn't save config.json: \(error.localizedDescription)") }
    }
}
