import Foundation
import Testing
@testable import MickIO
import MickCore

/// Settings, hand edits to config.json, the bell, open at login and uninstall
/// (§6.5, §11, §13), against a temporary MICK_HOME.
@MainActor
@Suite(.serialized) struct SettingsEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func start(_ temp: TempHome, log: MemoryLog = MemoryLog(), sys: FakeSystem? = nil) throws -> MickEngine {
        let sys = sys ?? FakeSystem(now: t0)
        var tunables = MickEngine.Tunables()
        tunables.configDebounce = 0.02
        let e = MickEngine(home: temp.home, log: log, tunables: tunables, clock: { sys.now }, idleSeconds: { sys.idle })
        try e.start()
        return e
    }

    private func write(_ json: String, to url: URL, atomically: Bool = true) throws {
        if atomically {
            try Data(json.utf8).write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(json.utf8))
            try handle.close()
        }
    }

    private func onDisk(_ temp: TempHome) throws -> ConfigFile.Parsed {
        ConfigFile.parse(try Data(contentsOf: temp.home.config))
    }

    // MARK: Settings write the file

    @Test func settingsAreWrittenToConfigJSON() throws {
        let temp = try TempHome()
        let e = try start(temp)
        defer { e.stop() }
        let new = MickConfig(sitThresholdMinutes: 40, breakResetMinutes: 8, showDelaySeconds: 15,
                             quietHours: QuietHours(start: "23:00", end: "06:30"), sound: true)
        e.updateConfig(new)
        #expect(e.config == new)
        #expect(try onDisk(temp) == .config(new, problems: []))
        let text = try String(contentsOf: temp.home.config, encoding: .utf8)
        #expect(text.contains(#""quiet_hours" : {"#) && text.contains(#""sound" : true"#))  // human-readable
    }

    @Test func settingsValuesOutOfRangeAreFixedAndLogged() throws {
        let temp = try TempHome()
        let log = MemoryLog()
        let e = try start(temp, log: log)
        defer { e.stop() }
        e.updateConfig(MickConfig(sitThresholdMinutes: 0, sound: true))
        #expect(e.config == MickConfig(sound: true))
        #expect(log.messages.contains { $0.contains("sit_threshold_minutes 0 is out of range") })
    }

    @Test func mickOwnSaveIsNotTakenForAHandEdit() async throws {
        let temp = try TempHome()
        let log = MemoryLog()
        let e = try start(temp, log: log)
        defer { e.stop() }
        e.updateConfig(MickConfig(sitThresholdMinutes: 33))
        try await Task.sleep(for: .milliseconds(200))
        e.reloadConfigIfChanged()
        #expect(!log.messages.contains { $0.contains("changed by hand") })
        #expect(e.config.sitThresholdMinutes == 33)
    }

    // MARK: Hand edits are picked up without a relaunch

    @Test func handEditIsPickedUpLive() async throws {
        let temp = try TempHome()
        let log = MemoryLog()
        let e = try start(temp, log: log)
        defer { e.stop() }
        #expect(e.config == .defaults)

        // An editor that replaces the file (write + rename), as most do.
        try write(#"{"sit_threshold_minutes": 7, "sound": true}"#, to: temp.home.config)
        #expect(await eventually { e.config == MickConfig(sitThresholdMinutes: 7, sound: true) })
        #expect(log.messages.contains { $0.contains("config.json changed by hand") })

        // An editor that overwrites in place.
        try write(#"{"sit_threshold_minutes": 9}"#, to: temp.home.config, atomically: false)
        #expect(await eventually { e.config == MickConfig(sitThresholdMinutes: 9) })

        // And the replaced file is still watched afterwards.
        try write(#"{"show_delay_seconds": 3}"#, to: temp.home.config)
        #expect(await eventually { e.config == MickConfig(showDelaySeconds: 3) })
    }

    @Test func invalidHandEditedValuesFallBackToDefaultsAndAreLogged() async throws {
        let temp = try TempHome()
        let log = MemoryLog()
        let e = try start(temp, log: log)
        defer { e.stop() }
        e.updateConfig(MickConfig(sitThresholdMinutes: 20, showDelaySeconds: 5))

        try write(#"{"sit_threshold_minutes": -3, "show_delay_seconds": "soon", "sound": true}"#, to: temp.home.config)
        #expect(await eventually { e.config == MickConfig(sound: true) })
        #expect(log.messages.contains { $0.contains("config.json: sit_threshold_minutes -3 is out of range") })
        #expect(log.messages.contains { $0.contains("config.json: show_delay_seconds \"soon\" isn't a whole number") })
        // The person's file is left as they wrote it, for them to fix.
        #expect(try String(contentsOf: temp.home.config, encoding: .utf8).contains("soon"))
    }

    @Test func unparseableHandEditKeepsCurrentSettingsUntilFixed() async throws {
        let temp = try TempHome()
        let log = MemoryLog()
        let e = try start(temp, log: log)
        defer { e.stop() }
        e.updateConfig(MickConfig(sitThresholdMinutes: 20))

        try write(#"{"sit_threshold_minutes": 30"#, to: temp.home.config)  // half-typed
        #expect(await eventually { log.messages.contains { $0.contains("isn't valid JSON") || $0.contains("not valid JSON") } })
        #expect(e.config == MickConfig(sitThresholdMinutes: 20))
        let entries = try FileManager.default.contentsOfDirectory(atPath: temp.home.url.path)
        #expect(!entries.contains { $0.contains(".corrupt-") })  // never moved aside while running

        try write(#"{"sit_threshold_minutes": 30}"#, to: temp.home.config)
        #expect(await eventually { e.config == MickConfig(sitThresholdMinutes: 30) })
    }

    @Test func deletedConfigMeansDefaults() async throws {
        let temp = try TempHome()
        let e = try start(temp)
        defer { e.stop() }
        e.updateConfig(MickConfig(sitThresholdMinutes: 20))
        try FileManager.default.removeItem(at: temp.home.config)
        #expect(await eventually { e.config == .defaults })
    }

    @Test func tickRereadsAMissedEdit() throws {
        let temp = try TempHome()
        let log = MemoryLog()
        let sys = FakeSystem(now: t0)
        let e = MickEngine(home: temp.home, log: log, clock: { sys.now }, idleSeconds: { sys.idle })
        try e.start()
        defer { e.stop() }
        try write(#"{"sit_threshold_minutes": 11}"#, to: temp.home.config)
        e.tick()
        #expect(e.config.sitThresholdMinutes == 11)
    }

    @Test func launchReadsAHandEditedFileLeniently() throws {
        let temp = try TempHome()
        try write(#"{"sit_threshold_minutes": "fifty", "sound": true}"#, to: temp.home.config)
        let log = MemoryLog()
        let e = try start(temp, log: log)
        defer { e.stop() }
        #expect(e.config == MickConfig(sound: true))
        #expect(e.configOutcome == .loaded)
        #expect(log.messages.contains { $0.contains("sit_threshold_minutes \"fifty\" isn't a whole number") })
    }

    @Test func launchStillMovesACorruptFileAside() throws {
        let temp = try TempHome()
        try write("not json", to: temp.home.config)
        let log = MemoryLog()
        let e = try start(temp, log: log)
        defer { e.stop() }
        guard case .corrupt(let moved?) = e.configOutcome else {
            Issue.record("expected corrupt, got \(e.configOutcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(try onDisk(temp) == .config(.defaults, problems: []))
        #expect(log.messages.contains { $0.contains("config.json corrupted") })
    }

    // MARK: Bell

    private func armed(_ temp: TempHome, sound: Bool) throws {
        var s = MickState.defaults(now: t0)
        s.sittingSince = t0.addingTimeInterval(-3600)
        s.lastActiveAt = t0
        s.lastEventAt = t0
        try JSONFileStore.save(s, to: temp.home.state)
        try JSONFileStore.save(MickConfig(sound: sound), to: temp.home.config)
    }

    @Test func bellRingsWhenAPanelAppearsOnlyIfOn() async throws {
        let temp = try TempHome()
        try armed(temp, sound: true)
        let sys = FakeSystem(now: t0)
        sys.idle = 10
        let e = try start(temp, sys: sys)
        defer { e.stop() }
        var rung = 0
        e.onBell = { rung += 1 }

        // A real reminder: prompt, then the show delay.
        try temp.append(line("prompt", t0.timeIntervalSince1970, "A"))
        e.flushTailer()
        #expect(await eventually { e.reminder.check != nil })
        #expect(rung == 0)  // nothing on screen yet
        sys.advance(30)
        e.runReminderTimers()
        #expect(e.reminder.panel != nil)
        #expect(rung == 1 && e.bellCount == 1)
        // Ticks and updates don't ring again.
        e.setReminderItem(0, ticked: true)
        #expect(rung == 1)
    }

    @Test func bellStaysQuietWhenOff() throws {
        let temp = try TempHome()
        try armed(temp, sound: false)
        let e = try start(temp)
        defer { e.stop() }
        var rung = 0
        e.onBell = { rung += 1 }
        #expect(e.stretchNow())
        #expect(e.reminder.panel != nil)
        #expect(rung == 0 && e.bellCount == 0)
    }

    @Test func bellRingsForStretchNowToo() throws {
        let temp = try TempHome()
        try armed(temp, sound: false)
        let e = try start(temp)
        defer { e.stop() }
        var rung = 0
        e.onBell = { rung += 1 }
        e.updateConfig(MickConfig(sound: true))  // turned on in Settings
        #expect(e.stretchNow())
        #expect(rung == 1)
    }

    // MARK: Open at login

    @Test func openAtLoginIsOnByDefaultOnFirstLaunchOnly() throws {
        let service = RecordingLoginItem()
        let log = MemoryLog()
        let item = LoginItemController(service: service, log: log)
        item.applyDefault(firstLaunch: false)
        #expect(service.registerCalls == 0 && !item.isOn)
        item.applyDefault(firstLaunch: true)
        #expect(service.registerCalls == 1 && item.isOn && item.note == nil)

        // The person turned it off; later launches leave that alone.
        item.setEnabled(false)
        item.applyDefault(firstLaunch: false)
        #expect(service.unregisterCalls == 1 && !item.isOn)
        // Already on: a first launch doesn't register twice.
        let on = RecordingLoginItem(status: .enabled)
        LoginItemController(service: on, log: log).applyDefault(firstLaunch: true)
        #expect(on.registerCalls == 0)
    }

    @Test func requiresApprovalShowsThePlainLine() {
        let service = RecordingLoginItem()
        service.statusAfterRegister = .requiresApproval
        let log = MemoryLog()
        let item = LoginItemController(service: service, log: log)
        item.setEnabled(true)
        #expect(item.isOn)
        #expect(item.note?.contains("System Settings → General → Login Items") == true)
        #expect(log.messages.contains { $0.contains("needs approval") })
    }

    @Test func registrationErrorsAreShownAndLogged() {
        let service = RecordingLoginItem()
        service.nextError = NSError(domain: "SMAppServiceErrorDomain", code: Int(kSMErrorLaunchDeniedByUserForTests),
                                    userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let log = MemoryLog()
        let item = LoginItemController(service: service, log: log)
        item.setEnabled(true)
        #expect(!item.isOn)
        #expect(item.errorMessage?.contains("System Settings → General → Login Items") == true)
        #expect(item.note == item.errorMessage)
        #expect(log.messages.contains { $0.contains("open at login: Couldn't turn on") })

        service.nextError = NSError(domain: "SMAppServiceErrorDomain", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid signature"])
        item.setEnabled(true)
        #expect(item.errorMessage == "Couldn't turn on open at login: Invalid signature (error 3).")
        item.setEnabled(true)  // succeeds: the error clears
        #expect(item.errorMessage == nil && item.isOn)
    }

    // MARK: Uninstall

    @Test func uninstallRemovesEverythingAndUnregisters() throws {
        let temp = try TempHome()
        try armed(temp, sound: false)
        let log = RotatingLog(url: temp.home.log)
        let sys = FakeSystem(now: t0)
        let e = MickEngine(home: temp.home, log: log, clock: { sys.now }, idleSeconds: { sys.idle })
        try e.start()
        try temp.append(line("prompt", t0.timeIntervalSince1970, "A"))
        e.flushTailer()
        let service = RecordingLoginItem(status: .enabled)
        let item = LoginItemController(service: service, log: log)

        let result = e.uninstall(loginItem: item)
        #expect(result == MickEngine.UninstallResult(removedHome: true, problems: []))
        #expect(!FileManager.default.fileExists(atPath: temp.home.url.path))
        #expect(service.unregisterCalls == 1 && !item.isOn)
        #expect(e.isUninstalled && !e.isRunning)

        // Nothing brings the folder back: quitting, saves, sleep, settings, logging.
        e.stop()
        e.willSleep()
        e.didWake()
        e.poll()
        e.updateConfig(MickConfig(sound: true))
        e.pause()
        log.log("after uninstall")
        #expect(!FileManager.default.fileExists(atPath: temp.home.url.path))
    }

    @Test func uninstallLeavesAnUnregisteredLoginItemAlone() throws {
        let temp = try TempHome()
        let e = try start(temp)
        let service = RecordingLoginItem(status: .notRegistered)
        e.uninstall(loginItem: LoginItemController(service: service, log: MemoryLog()))
        #expect(service.unregisterCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: temp.home.url.path))
    }

    @Test func uninstallReportsAnUnregisterError() throws {
        let temp = try TempHome()
        let e = try start(temp)
        let service = RecordingLoginItem(status: .enabled)
        service.nextError = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nope"])
        let result = e.uninstall(loginItem: LoginItemController(service: service, log: MemoryLog()))
        #expect(result.removedHome)
        #expect(result.problems == ["Couldn't turn off open at login: Nope (error 1)."])
    }

    /// Pure check only: never points a real uninstall at a real directory.
    @Test func uninstallRefusesObviouslyWrongFolders() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(!MickEngine.isSafeToDelete(URL(fileURLWithPath: "/"), userHome: home))
        #expect(!MickEngine.isSafeToDelete(URL(fileURLWithPath: "/Users/someone"), userHome: home))
        #expect(!MickEngine.isSafeToDelete(URL(fileURLWithPath: "/Users/someone/"), userHome: home))
        #expect(!MickEngine.isSafeToDelete(URL(fileURLWithPath: "/Users/someone/../someone"), userHome: home))
        #expect(!MickEngine.isSafeToDelete(URL(fileURLWithPath: "/Users"), userHome: home))
        #expect(MickEngine.isSafeToDelete(URL(fileURLWithPath: "/Users/someone/.mick"), userHome: home))
        #expect(MickEngine.isSafeToDelete(URL(fileURLWithPath: "/tmp/mick-test/home"), userHome: home))
    }

    /// After uninstall, a still-installed plugin's hook writes nothing and creates
    /// nothing (§6.1, §13): the real script, run against the deleted home.
    @Test func hookAfterUninstallCreatesNothing() throws {
        let hook = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // MickCore
            .deletingLastPathComponent().deletingLastPathComponent()  // repo root
            .appendingPathComponent("plugin/hooks/mick-event.sh")
        try #require(FileManager.default.isExecutableFile(atPath: hook.path), "hook script at \(hook.path)")

        let temp = try TempHome()
        let e = try start(temp)
        e.uninstall(loginItem: nil)
        #expect(!FileManager.default.fileExists(atPath: temp.home.url.path))

        for kind in ["prompt", "stop", "wait", "end"] {
            let process = Process()
            process.executableURL = hook
            process.arguments = [kind]
            process.environment = ["MICK_HOME": temp.home.url.path, "PATH": "/usr/bin:/bin"]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stdout
            try process.run()
            stdin.fileHandleForWriting.write(Data(#"{"session_id":"A","cwd":"/tmp","prompt":"secret"}"#.utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: temp.home.url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.root.path).isEmpty)
    }
}

/// `kSMErrorLaunchDeniedByUser`, spelled out so the test doesn't import ServiceManagement.
let kSMErrorLaunchDeniedByUserForTests: Int32 = 11
