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
        public init() {}
    }

    public let home: MickHome
    @ObservationIgnored public let log: any MickLogger
    @ObservationIgnored private let clock: @Sendable () -> Date
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

    public init(home: MickHome, log: any MickLogger, tunables: Tunables = Tunables(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.log = log
        self.tunables = tunables
        self.clock = clock
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
        isRunning = true
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
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
